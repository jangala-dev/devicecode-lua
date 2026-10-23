local bit = require 'bit'
local posix = require 'posix'
local clock = require 'posix.time'
local errno = require 'posix.errno'
local fcntl = require 'posix.fcntl'
local signals = require 'posix.signal'
local stat = require 'posix.sys.stat'
local auth = require 'onbox.support.auth'
local fiber_runtime = require 'onbox.support.fiber_runtime'
local util = require 'onbox.support.util'

local M = {}
local current_state
local launch_gate = { owner_token = nil, waiters = {} }
local managed_active = 0

local WRAPPER = [[
umask 077
test ! -e "$1" || exit 125
printf '%s\n' "$$" > "$1" || exit 125
shift
exec "$@"
]]

function M.quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

---Blocking preflight helper. Active test commands use fibers.io.exec instead.
function M.execute(command)
    assert(managed_active == 0 and not launch_gate.owner_token and not auth.has_active_leases(),
        'Blocking process.execute is forbidden while managed processes or credentials are active')
    local ok, _, code = os.execute(command)
    if type(ok) == 'number' then
        return ok == 0 and 0 or (ok < 256 and 128 + ok or math.floor(ok / 256))
    end
    return ok and 0 or (code or 1)
end

function M.set_run_state(state) current_state = state end

local function interrupt_op(state)
    local f = fiber_runtime.get()
    if not state or state.recovering or not state.interrupt_notification then return f.op.never() end
    return fiber_runtime.oneshot_op(state.interrupt_notification)
end

local function poison_launch_gate(reason)
    if not launch_gate.poison then launch_gate.poison = tostring(reason or 'unverifiable process containment') end
end

local function release_launch_gate(token)
    assert(token and launch_gate.owner_token == token and token.state == 'granted',
        'Global launch gate released by a non-owner')
    token.state = 'released'
    if launch_gate.poison then
        launch_gate.owner_token = nil
        for _, waiter in ipairs(launch_gate.waiters) do
            if waiter.state == 'queued' then waiter.state = 'cancelled'; waiter.ready:signal() end
        end
        launch_gate.waiters = {}
        return
    end
    while #launch_gate.waiters > 0 do
        local waiter = table.remove(launch_gate.waiters, 1)
        if waiter.state == 'queued' then
            waiter.state = 'granted'
            launch_gate.owner_token = waiter
            waiter.ready:signal()
            return
        end
    end
    launch_gate.owner_token = nil
end

local function acquire_launch_gate(state, wait)
    assert(not launch_gate.poison, 'Process launch gate is poisoned: ' .. tostring(launch_gate.poison))
    local token = { state = 'queued' }
    if not launch_gate.owner_token then
        token.state = 'granted'
        launch_gate.owner_token = token
        return token
    end
    assert(wait, 'Another support-managed process launch is in progress')
    local f = fiber_runtime.get()
    token.ready = f.oneshot.new()
    launch_gate.waiters[#launch_gate.waiters + 1] = token
    local acquired = f.fibers.perform(f.op.choice(
        fiber_runtime.oneshot_op(token.ready):wrap(function() return true end),
        interrupt_op(state):wrap(function() return false end)))
    if not acquired or (state and state.interrupted and not state.recovering) then
        if token.state == 'queued' then token.state = 'cancelled'
        elseif token.state == 'granted' then release_launch_gate(token) end
        error('Interrupted', 0)
    end
    assert(not launch_gate.poison, 'Process launch gate is poisoned: ' .. tostring(launch_gate.poison))
    assert(token.state == 'granted' and launch_gate.owner_token == token,
        'Global launch gate grant was lost')
    return token
end

local function validate_leases(leases)
    local seen, validated = {}, {}
    for _, lease in ipairs(leases or {}) do
        assert(not seen[lease], 'Credential lease listed more than once')
        seen[lease] = true
        auth.lease_fd(lease)
        assert(not auth.lease_is_inheritable(lease), 'Credential lease must be close-on-exec before launch')
        validated[#validated + 1] = lease
    end
    return validated
end

local function retire_leases(leases)
    local errors = {}
    for _, lease in ipairs(leases or {}) do
        local restored, restore_err = pcall(function()
            if auth.lease_is_inheritable(lease) then auth.set_lease_inheritable(lease, false) end
        end)
        local closed, close_err = pcall(auth.close_lease, lease)
        if not restored then errors[#errors + 1] = tostring(restore_err) end
        if not closed then errors[#errors + 1] = tostring(close_err) end
    end
    if #errors > 0 then
        poison_launch_gate(table.concat(errors, '\n'))
        error(table.concat(errors, '\n'), 0)
    end
end

function M.pause(seconds)
    assert(type(seconds) == 'number' and seconds >= 0, 'Invalid pause')
    if not fiber_runtime.in_fiber() then
        local ok = clock.nanosleep({ tv_sec = math.floor(seconds),
            tv_nsec = math.floor((seconds % 1) * 1e9) })
        assert(ok, 'Interrupted')
        return
    end
    local f = fiber_runtime.get()
    if current_state and current_state.interrupted and not current_state.recovering then error('Interrupted', 0) end
    if not current_state or current_state.recovering then f.sleep.sleep(seconds); return end
    local which = f.fibers.perform(f.op.named_choice({
        pause = f.sleep.sleep_op(seconds), interrupt = interrupt_op(current_state),
    }))
    if which == 'interrupt' then error('Interrupted', 0) end
end

function M.now()
    local value = assert(clock.clock_gettime(clock.CLOCK_MONOTONIC))
    return value.tv_sec + value.tv_nsec / 1e9
end

---Parse Linux /proc/PID/stat, whose parenthesized comm field may contain spaces and parentheses.
---@param content string
---@return table identity
function M.parse_proc_stat(content)
    local pid_text, comm, state, fields = content:match('^(%d+) %((.*)%) ([%a]) (.-)%s*$')
    assert(pid_text and fields ~= '', 'Invalid /proc stat record')
    local values = {}
    for token in fields:gmatch('%S+') do
        assert(token:match('^-?%d+$'), 'Invalid numeric field in /proc stat record')
        values[#values + 1] = assert(tonumber(token), 'Invalid number in /proc stat record')
    end
    assert(#values >= 19, 'Truncated /proc stat record')
    return { pid = assert(tonumber(pid_text)), comm = comm, state = state,
        pgrp = values[2], sid = values[3], starttime = values[19] }
end

local function read_proc_stat(pid)
    local path = '/proc/' .. tostring(pid) .. '/stat'
    local fd, open_err, open_errno = posix.open(path, posix.O_RDONLY)
    if not fd then return nil, open_err, open_errno end
    local content, read_err, read_errno = posix.read(fd, 8192)
    posix.close(fd)
    if not content then return nil, read_err, read_errno end
    local ok, identity = pcall(M.parse_proc_stat, content)
    if not ok then return nil, identity, nil end
    return identity
end

local function capture_group_identity(pgid, background)
    local deadline, detail = M.now() + 1, 'not observed'
    while true do
        local identity, err, eno = read_proc_stat(pgid)
        if identity and identity.pid == pgid and identity.pgrp == pgid
            and (not background or identity.sid == pgid) then
            return identity
        end
        detail = identity and ('pid=%s pgrp=%s sid=%s'):format(
            tostring(identity.pid), tostring(identity.pgrp), tostring(identity.sid)) or tostring(err or eno)
        if M.now() >= deadline then
            error(('Process leader identity is invalid: %s'):format(detail), 0)
        end
        if fiber_runtime.in_fiber() then fiber_runtime.get().sleep.sleep(0.01)
        else clock.nanosleep({ tv_sec = 0, tv_nsec = 10000000 }) end
    end
end

local function identity_matches(expected)
    local current, err, eno = read_proc_stat(expected.pid)
    if not current then
        if eno == errno.ENOENT or not posix.stat('/proc/' .. expected.pid) then return false, 'absent' end
        return false, 'inconclusive: ' .. tostring(err or eno)
    end
    if current.pid ~= expected.pid or current.pgrp ~= expected.pgrp or current.sid ~= expected.sid
        or current.starttime ~= expected.starttime then
        return false, 'identity mismatch'
    end
    return true, current
end

---Classify every visible member of a Linux process group.
---@param pgid integer
---@return string status ABSENT|ZOMBIES_ONLY|LIVE|INCONCLUSIVE
---@return integer[] zombies
---@return string? detail
function M.classify_group(pgid)
    assert(type(pgid) == 'number' and pgid > 1 and pgid == math.floor(pgid), 'Invalid process group')
    local listed, names = pcall(function()
        local result = {}
        for name in posix.files('/proc') do
            if name:match('^[1-9][0-9]*$') then result[#result + 1] = tonumber(name) end
        end
        return result
    end)
    if not listed then return 'INCONCLUSIVE', {}, tostring(names) end
    local members, zombies = 0, {}
    for _, pid in ipairs(names) do
        local identity, err, eno = read_proc_stat(pid)
        if not identity then
            if eno ~= errno.ENOENT and posix.stat('/proc/' .. pid) then
                return 'INCONCLUSIVE', zombies, ('Cannot inspect /proc/%d/stat: %s'):format(pid, tostring(err or eno))
            end
        elseif identity.pgrp == pgid then
            members = members + 1
            if identity.state == 'Z' then zombies[#zombies + 1] = pid
            else return 'LIVE', zombies end
        end
    end
    table.sort(zombies)
    if members == 0 then return 'ABSENT', zombies end
    return 'ZOMBIES_ONLY', zombies
end

local function assert_proc_supported()
    local pid = assert(posix.getpid().pid)
    local identity, err = read_proc_stat(pid)
    assert(identity and identity.pid == pid, 'Linux /proc process identity is unavailable: ' .. tostring(err))
end

local Process = {}
Process.__index = Process

function M.new(artifacts, state)
    return setmetatable({ artifacts = artifacts, state = state or {}, active = {}, by_pid = {}, legacy = {},
        tombstone = {},
        foreground_busy = false, foreground_waiters = {} }, Process)
end

function Process:check_interrupted()
    assert(not self.poison, 'Process manager is poisoned: ' .. tostring(self.poison))
    assert(not self.state.interrupted or self.state.recovering, 'Interrupted')
end

function Process:_poison(reason)
    if not self.poison then self.poison = tostring(reason) end
end

local function close_stream(stream, raw)
    if not stream then return true end
    if raw then return fiber_runtime.get().op.perform_raw(stream:close_op()) end
    local ok, err = stream:close()
    return ok ~= nil, err
end

local function set_fd_cloexec(fd, enabled)
    local flags = assert(fcntl.fcntl(fd, fcntl.F_GETFD), 'Cannot inspect input descriptor flags')
    local cloexec = fcntl.FD_CLOEXEC or 1
    local updated = enabled and bit.bor(flags, cloexec) or bit.band(flags, bit.bnot(cloexec))
    assert(fcntl.fcntl(fd, fcntl.F_SETFD, updated), 'Cannot update input descriptor flags')
end

local function open_input_fd(path)
    path = path or '/dev/null'
    local flags = bit.bor(fcntl.O_RDONLY or 0, fcntl.O_NONBLOCK or 2048, fcntl.O_CLOEXEC or 0)
    local fd, open_err = posix.open(path, flags)
    assert(fd, open_err)
    local ok, result = pcall(function()
        set_fd_cloexec(fd, true)
        local info = assert(posix.fstat(fd), 'Cannot inspect process input descriptor')
        assert(stat.S_ISREG(info.st_mode) ~= 0
            or (path == '/dev/null' and stat.S_ISCHR(info.st_mode) ~= 0),
            'Unsupported process input type; expected regular file or /dev/null')
        local status_flags = assert(fcntl.fcntl(fd, fcntl.F_GETFL), 'Cannot inspect process input status')
        if bit.band(status_flags, fcntl.O_NONBLOCK or 2048) ~= 0 then
            assert(fcntl.fcntl(fd, fcntl.F_SETFL,
                bit.band(status_flags, bit.bnot(fcntl.O_NONBLOCK or 2048))),
                'Cannot clear nonblocking mode on process input')
        end
        return fd, path
    end)
    if not ok then posix.close(fd); error(result, 0) end
    return result, path
end

local function read_if_complete(path)
    local file = io.open(path, 'rb')
    if not file then return nil end
    local content = file:read('*a')
    file:close()
    -- A final newline is the wrapper's commit marker.  Before it appears the
    -- scheduler may simply have observed the file between write(2) calls.
    if content:sub(-1) ~= '\n' then return nil end
    assert(content:match('^[1-9][0-9]*\n$'), 'Invalid process handoff content')
    return content
end

function Process:_read_handoff(handle)
    local content = read_if_complete(handle.pid_path)
    if not content then return nil end
    local info = assert(posix.lstat(handle.pid_path), 'Cannot inspect process handoff')
    assert(stat.S_ISREG(info.st_mode) ~= 0, 'Invalid process handoff type')
    assert(info.st_uid == posix.getuid(), 'Invalid process handoff owner')
    assert(info.st_nlink == 1, 'Invalid process handoff link count')
    assert(bit.band(info.st_mode, stat.S_IRWXU + stat.S_IRWXG + stat.S_IRWXO) == 384,
        'Invalid process handoff permissions')
    local pid = assert(tonumber(content:match('^([1-9][0-9]*)\n$')), 'Invalid process handoff content')
    assert(pid > 1 and pid == math.floor(pid), 'Invalid process group ID')
    return pid
end

local function remove_workspace(handle)
    local errors = {}
    local function remove(path, directory)
        if not path then return end
        local ok, err, eno
        if directory then ok, err, eno = posix.rmdir(path)
        else ok, err, eno = os.remove(path) end
        if ok then return end
        local _, _, stat_errno = posix.lstat(path)
        if eno == errno.ENOENT or stat_errno == errno.ENOENT then return end
        errors[#errors + 1] = ('Cannot remove %s: %s'):format(path, tostring(err or eno))
    end
    remove(handle.pid_path, false)
    remove(handle.workspace, true)
    handle.workspace_cleanup_errors = #errors > 0 and errors or nil
    assert(#errors == 0, table.concat(errors, '\n'))
end

local function signal_group(pgid, signal)
    local ok, err, eno = signals.kill(-pgid, signal)
    if ok == 0 or ok == true then return true end
    if eno == errno.ESRCH then return false end
    error(('Cannot signal process group %d: %s'):format(pgid, tostring(err)), 0)
end

local function group_exists(pgid)
    local ok, err, eno = signals.kill(-pgid, 0)
    if ok == 0 or ok == true then return true end
    if eno == errno.ESRCH then return false end
    if eno == errno.EPERM then error('Permission denied probing process group ' .. pgid, 0) end
    error(('Cannot probe process group %d: %s'):format(pgid, tostring(err)), 0)
end

local function validate_delayed_identity(identity)
    local matched, current_or_reason = identity_matches(identity)
    if matched then return true end
    if current_or_reason == 'absent' then
        local status, zombies, detail = M.classify_group(identity.pgrp)
        if status == 'ABSENT' then return false, zombies end
        error(('Background leader is absent while process group %d remains %s%s'):format(
            identity.pgrp, status, detail and (': ' .. detail) or ''), 0)
    end
    error(('Background process identity validation failed for %d: %s'):format(
        identity.pid, tostring(current_or_reason)), 0)
end

local function reap_group_children(pgid)
    for _ = 1, 256 do
        local ok, pid = pcall(posix.wait, -pgid, posix.WNOHANG)
        if not ok or not pid or pid == 0 then return end
    end
end

local function wait_for_containment(pgid, pause)
    local deadline = M.now() + 5
    while true do
        reap_group_children(pgid)
        local status, zombies, detail = M.classify_group(pgid)
        if status == 'ABSENT' or status == 'ZOMBIES_ONLY' then return status, zombies end
        if M.now() >= deadline then
            error(('Process group %d containment is %s%s'):format(
                pgid, status, detail and (': ' .. detail) or ''), 0)
        end
        pause()
    end
end

function Process:_wait_completed(handle, raw)
    if handle.result then return handle.result end
    local f = fiber_runtime.get()
    if raw then
        local status, code, signal, wait_err = f.op.perform_raw(handle.command:run_op())
        handle.result = { status = status, code = code, signal = signal, err = wait_err }
        handle.completed:signal()
        self:_publish(handle, 'terminal', handle.result)
    else
        f.fibers.perform(fiber_runtime.oneshot_op(handle.completed))
    end
    return assert(handle.result)
end

function Process:_wait_feeder(handle, raw)
    if handle.feeder_state == 'not_started' or handle.feeder_state == 'done' then return end
    assert(handle.feeder_state == 'running', 'Invalid feeder state: ' .. tostring(handle.feeder_state))
    local f = fiber_runtime.get()
    local op = fiber_runtime.oneshot_op(handle.feeder_done)
    local joined
    local bounded = f.op.choice(
        op:wrap(function() return true end),
        f.sleep.sleep_op(5):wrap(function() return false end))
    if raw then joined = f.op.perform_raw(bounded) else joined = f.fibers.perform(bounded) end
    assert(joined, 'Timed out waiting for process input feeder')
end

function Process:_publish(handle, kind, payload)
    handle.outcome_sequence = handle.outcome_sequence + 1
    if handle.outcome then return false end
    handle.outcome = { kind = kind, payload = payload, sequence = handle.outcome_sequence }
    handle.outcome_ready:signal()
    return true
end

function Process:_cancel_feeder(handle, reason)
    handle.feeder_cancelled = true
    if handle.source then pcall(function() handle.source:terminate(reason) end) end
    if handle.stdin then pcall(function() handle.stdin:terminate(reason) end) end
end

function Process:_close_input(handle, raw)
    if handle.input_closed then return end
    local source = handle.source
    if not source then handle.input_closed = true; return end
    local ok, err = close_stream(source, raw)
    assert(ok, err)
    handle.source = nil
    handle.input_closed = true
end

function Process:_close_handle(handle, raw)
    if handle.closed then return end
    if handle.source then
        pcall(function() handle.source:terminate('onbox_close') end)
        self:_close_input(handle, raw)
    end
    if handle.stdin then pcall(function() handle.stdin:terminate('onbox_close') end); handle.stdin = nil end
    local errors = {}
    local retained = {}
    for _, stream in ipairs(handle.outputs) do
        local ok, err = close_stream(stream, raw)
        if not ok then errors[#errors + 1] = tostring(err); retained[#retained + 1] = stream end
    end
    handle.outputs = retained
    assert(#errors == 0, table.concat(errors, '\n'))
    remove_workspace(handle)
    handle.closed = true
    if handle.pgid then
        self.by_pid[handle.pgid] = nil
        self.tombstone[handle.pgid] = true
    end
    self.active[handle] = nil
    managed_active = managed_active - 1
    handle.workspace_cleanup_errors = nil
end

function Process:_shutdown_group(handle, grace, raw)
    local f = fiber_runtime.get()
    local function pause()
        if raw then f.op.perform_raw(f.sleep.sleep_op(0.05)) else f.sleep.sleep(0.05) end
    end
    local pgid = assert(handle.pgid, 'Process group handoff was not completed')
    self:_cancel_feeder(handle, 'process_stopped')
    assert(handle.identity, 'Process identity was not captured')
    local validated, should_signal = pcall(validate_delayed_identity, handle.identity)
    if not validated then self:_poison(should_signal); error(should_signal, 0) end
    if should_signal and group_exists(pgid) then signal_group(pgid, signals.SIGTERM or 15) end
    local deadline = M.now() + (grace or 2)
    while group_exists(pgid) and M.now() < deadline do pause() end
    if should_signal and group_exists(pgid) then signal_group(pgid, signals.SIGKILL or 9) end
    self:_wait_completed(handle, raw)
    local contained, status, zombies = pcall(wait_for_containment, pgid, pause)
    if not contained then self:_poison(status); error(status, 0) end
    handle.containment, handle.zombies = status, zombies
    self:_wait_feeder(handle, raw)
end

function Process:_shutdown_unidentified(handle, raw)
    local f = fiber_runtime.get()
    self:_cancel_feeder(handle, 'unidentified_background')
    local status, code, signal, shutdown_err
    if raw then status, code, signal, shutdown_err = f.op.perform_raw(handle.command:shutdown_op(2))
    else status, code, signal, shutdown_err = f.fibers.perform(handle.command:shutdown_op(2)) end
    handle.result = { status = status, code = code, signal = signal, err = shutdown_err }
    handle.completed:signal()
    self:_publish(handle, 'terminal', handle.result)
    self:_wait_feeder(handle, raw)
    self:_poison('Command identity was not captured; full process-group containment is unverifiable')
    error('Process leader was stopped through its command handle, but full process-group containment '
        .. 'cannot be established without a validated identity', 0)
end

function Process:_finish_normal(handle)
    self:_cancel_feeder(handle, 'process_complete')
    self:_wait_feeder(handle)
    if handle.pgid then self:_shutdown_group(handle, 0.2) end
end

local function result_code(result)
    if result.status == 'exited' then return assert(result.code, 'Missing process exit code') end
    if result.status == 'signalled' then return 128 + assert(result.signal, 'Missing process signal') end
    error('Process execution failed: ' .. tostring(result.err or result.status), 0)
end

function Process:_spawn_waiter(handle)
    local f = fiber_runtime.get()
    local ok, err = f.fibers.spawn(function()
        local performed, status, code, signal, wait_err = pcall(f.fibers.perform, handle.command:run_op())
        if performed then handle.result = { status = status, code = code, signal = signal, err = wait_err }
        else handle.result = { status = 'failed', err = status } end
        handle.completed:signal()
        self:_publish(handle, 'terminal', handle.result)
    end)
    assert(ok, err)
end

function Process:_start_feeder(handle)
    local f = fiber_runtime.get()
    handle.feeder_state = 'running'
    local ok, err = f.fibers.spawn(function()
        local secondary = false
        local passed, failure = pcall(function()
            local source = assert(handle.source, 'Process input stream is unavailable')
            if handle.feeder_cancelled then
                source:terminate('feed_cancelled')
                self:_close_input(handle)
                return
            end
            local feed_ok, feed_err = pcall(function()
                while true do
                    local chunk, read_err = source:read_some(65536)
                    assert(not read_err, read_err)
                    if not chunk then break end
                    local count, write_err = handle.stdin:write(chunk)
                    if count ~= #chunk then
                        local detail = tostring(write_err or 'Short process input write')
                        local lower = detail:lower()
                        secondary = lower:find('broken pipe', 1, true)
                            or lower:find('peer', 1, true) or lower:find('closed', 1, true)
                        error(write_err or 'Short process input write', 0)
                    end
                end
            end)
            local input_closed, input_close_err = pcall(function() self:_close_input(handle) end)
            if not feed_ok then
                if not input_closed then
                    error(tostring(feed_err) .. '\nInput cleanup failed: ' .. tostring(input_close_err), 0)
                end
                error(feed_err, 0)
            end
            assert(input_closed, input_close_err)
            local closed_in, close_in_err = handle.stdin:close()
            if not closed_in then
                local lower = tostring(close_in_err):lower()
                secondary = lower:find('broken pipe', 1, true)
                    or lower:find('peer', 1, true) or lower:find('closed', 1, true)
                error(close_in_err, 0)
            end
            handle.stdin = nil
        end)
        if not passed then
            handle.feeder_error = failure
            if secondary then
                handle.feeder_secondary = failure
            else
                handle.feeder_failed:signal()
                self:_publish(handle, 'feeder', failure)
            end
        end
        handle.feeder_state = 'done'
        handle.feeder_done:signal()
    end)
    if not ok then handle.feeder_state = 'not_started'; error(err, 0) end
end

function Process:_launch(command, opts, background, on_handle)
    local f = fiber_runtime.get()
    local input_fd, input_path = open_input_fd(opts.input_path)
    local wrapped, input = pcall(f.file.fdopen, input_fd, 'r', input_path)
    if not wrapped then posix.close(input_fd); error(input, 0) end
    local acquired, gate_token = pcall(acquire_launch_gate, self.state, true)
    if not acquired then
        local closed, close_err = close_stream(input, true)
        if not closed then error(tostring(gate_token) .. '\nInput cleanup failed: ' .. tostring(close_err), 0) end
        error(gate_token, 0)
    end
    local gate_held = true
    local leases, workspace, pid_path, outputs, handle
    local leases_retired = false
    local spawned = false

    local function finish_gate(poison)
        local errors = {}
        if not leases_retired then
            leases_retired = true
            local retired, retire_err = pcall(function() retire_leases(leases) end)
            if not retired then errors[#errors + 1] = tostring(retire_err) end
        end
        if poison then poison_launch_gate(poison) end
        if gate_held then release_launch_gate(gate_token); gate_held = false end
        if #errors > 0 then error(table.concat(errors, '\n'), 0) end
    end

    local launched, launch_err = pcall(function()
        leases = validate_leases(opts.inherit_fds)
        workspace = assert(posix.mkdtemp(self.artifacts .. '/.process-XXXXXX'))
        assert(posix.chmod(workspace, 'rwx------'))
        pid_path = workspace .. '/pid'
        assert(not posix.lstat(pid_path), 'Process handoff already exists')
        local stdout_path = opts.log_path or (self.artifacts .. '/command.stdout')
        local stderr_path = opts.log_path and nil or (self.artifacts .. '/command.stderr')
        local stdout, stdout_err = f.file.open(stdout_path, 'w')
        assert(stdout, stdout_err)
        outputs = { stdout }
        local stderr
        if not opts.log_path then
            local stream, stream_err = f.file.open(stderr_path, 'w')
            assert(stream, stream_err)
            stderr, outputs[#outputs + 1] = stream, stream
        end
        local argv = background
            and { 'setsid', 'sh', '-c', WRAPPER, 'onbox-command', pid_path, 'sh', '-c', command }
            or { 'sh', '-c', WRAPPER, 'onbox-command', pid_path, 'sh', '-c', command }
        local spec = { stdin = 'pipe', stdout = stdout, stderr = opts.log_path and 'stdout' or stderr,
            flags = background and nil or { process_group = true } }
        for i, value in ipairs(argv) do spec[i] = value end
        local cmd = f.exec.command(spec)
        handle = { command = cmd, workspace = workspace, pid_path = pid_path,
            stdout_path = stdout_path, stderr_path = stderr_path, outputs = outputs,
            source = input,
            completed = f.oneshot.new(), feeder_done = f.oneshot.new(), feeder_failed = f.oneshot.new(),
            outcome_ready = f.oneshot.new(), lifecycle_done = f.oneshot.new(), outcome_sequence = 0,
            feeder_state = 'not_started', background = background }
        self.active[handle] = true
        managed_active = managed_active + 1
        if on_handle then on_handle(handle) end
        for _, lease in ipairs(leases) do auth.set_lease_inheritable(lease, true) end
        local stdin, start_err = cmd:stdin_stream()
        assert(stdin, 'Cannot start process: ' .. tostring(start_err))
        spawned = true
        handle.stdin = stdin
        local launch_deadline = M.now() + math.min(opts.timeout or 40, 10)
        while not handle.pgid do
            handle.pgid = self:_read_handoff(handle)
            if handle.pgid then break end
            if self.state.interrupted and not self.state.recovering then error('Interrupted', 0) end
            assert(M.now() < launch_deadline, 'Timed out waiting for process group handoff')
            f.sleep.sleep(0.01)
        end
        handle.identity = capture_group_identity(handle.pgid, background)
        self:_spawn_waiter(handle)
        self.by_pid[handle.pgid] = handle
        self:_start_feeder(handle)
    end)

    if launched then
        local finalized, final_err = pcall(finish_gate)
        if finalized then return handle end
        launched, launch_err = false, final_err
    end

    if handle then handle.lifecycle_done:signal() end
    local cleaned, cleanup_err = pcall(function()
        if handle then
            if spawned then
                if not handle.identity then
                    self:_shutdown_unidentified(handle, true)
                elseif handle.pgid then
                    self:_shutdown_group(handle, 2, true)
                else
                    if handle.stdin then handle.stdin:terminate('launch_failed') end
                    f.op.perform_raw(handle.command:shutdown_op(2))
                end
            end
            self:_close_handle(handle, true)
        else
            local cleanup_errors = {}
            for _, stream in ipairs(outputs or {}) do pcall(function() stream:terminate('setup_failed') end) end
            if workspace then
                local removed, remove_err = pcall(remove_workspace, { pid_path = pid_path, workspace = workspace })
                if not removed then cleanup_errors[#cleanup_errors + 1] = tostring(remove_err) end
            end
            local input_closed, input_close_err = close_stream(input, true)
            if not input_closed then cleanup_errors[#cleanup_errors + 1] = tostring(input_close_err) end
            assert(#cleanup_errors == 0, table.concat(cleanup_errors, '\n'))
        end
    end)
    local containment_error = spawned and not cleaned and ('Launch containment failed: ' .. tostring(cleanup_err)) or nil
    local finalized, final_err = pcall(finish_gate, containment_error)
    local errors = { tostring(launch_err) }
    if not cleaned then errors[#errors + 1] = 'Launch cleanup failed: ' .. tostring(cleanup_err) end
    if not finalized then errors[#errors + 1] = 'Credential cleanup failed: ' .. tostring(final_err) end
    error(table.concat(errors, '\n'), 0)
end

function Process:_spawn_outcome_publishers(handle, timeout)
    local f = fiber_runtime.get()
    assert(f.fibers.spawn(function()
        local selected = f.fibers.perform(f.op.choice(
            interrupt_op(self.state):wrap(function() return 'interrupt' end),
            fiber_runtime.oneshot_op(handle.lifecycle_done):wrap(function() return 'done' end)))
        if selected == 'interrupt' then self:_publish(handle, 'interrupt') end
    end))
    assert(f.fibers.spawn(function()
        local selected = f.fibers.perform(f.op.choice(
            f.sleep.sleep_op(math.max(0, timeout)):wrap(function() return 'timeout' end),
            fiber_runtime.oneshot_op(handle.lifecycle_done):wrap(function() return 'done' end)))
        if selected == 'timeout' then self:_publish(handle, 'timeout') end
    end))
end

function Process:_run_serialized(command, opts)
    local timeout = opts.timeout or 40
    local handle = self:_launch(command, opts, false, function(starting)
        self:_spawn_outcome_publishers(starting, timeout)
    end)
    fiber_runtime.get().fibers.perform(fiber_runtime.oneshot_op(handle.outcome_ready))
    local winner = assert(handle.outcome).kind
    local code
    local cleanup_complete = false
    local ok, err = pcall(function()
        if winner == 'terminal' then
            self:_finish_normal(handle)
            cleanup_complete = true
            code = result_code(assert(handle.result))
        else
            self:_shutdown_group(handle, 5)
            cleanup_complete = true
            if winner == 'timeout' then code = 124
            elseif winner == 'interrupt' then self.state.interrupted = true; error('Interrupted', 0)
            else error('Process input failed: ' .. tostring(handle.feeder_error), 0) end
        end
    end)
    handle.lifecycle_done:signal()
    if cleanup_complete then
        local closed, close_err = pcall(function() self:_close_handle(handle) end)
        if not closed then
            if not ok then error(tostring(err) .. '\nCleanup failed: ' .. tostring(close_err), 0) end
            error(close_err, 0)
        end
    end
    if not ok then error(err, 0) end
    return { stdout = util.read(handle.stdout_path),
        stderr = handle.stderr_path and util.read(handle.stderr_path) or '', code = code }
end

function Process:_acquire_foreground()
    if not self.foreground_busy then self.foreground_busy = true; return end
    local f = fiber_runtime.get()
    local waiter = { ready = f.oneshot.new() }
    self.foreground_waiters[#self.foreground_waiters + 1] = waiter
    local acquired = f.fibers.perform(f.op.choice(
        fiber_runtime.oneshot_op(waiter.ready):wrap(function() return true end),
        interrupt_op(self.state):wrap(function() return false end)))
    if not acquired then waiter.cancelled = true; error('Interrupted', 0) end
    if self.state.interrupted and not self.state.recovering then
        self:_release_foreground()
        error('Interrupted', 0)
    end
end

function Process:_release_foreground()
    assert(self.foreground_busy, 'Foreground process gate released while idle')
    while #self.foreground_waiters > 0 do
        local waiter = table.remove(self.foreground_waiters, 1)
        if not waiter.cancelled then waiter.ready:signal(); return end
    end
    self.foreground_busy = false
end

function Process:_run_fiber(command, opts)
    self:check_interrupted()
    opts = opts or {}
    self:_acquire_foreground()
    local ok, result = pcall(function() return self:_run_serialized(command, opts) end)
    self:_release_foreground()
    if not ok then error(result, 0) end
    return result
end

function Process:run(command, opts)
    if fiber_runtime.in_fiber() then return self:_run_fiber(command, opts) end
    local f = fiber_runtime.get()
    return f.fibers.run(function() return self:_run_fiber(command, opts) end)
end

local function legacy_start(command, log_path, input_fd)
    assert(type(input_fd) == 'number' and input_fd >= 0 and input_fd == math.floor(input_fd),
        'Invalid legacy input descriptor')
    local shell = 'setsid ' .. command .. ' > ' .. M.quote(log_path)
        .. ' 2>&1 <&' .. tostring(input_fd) .. ' & echo $!'
    local pipe = assert(io.popen(shell, 'r'))
    local pid = tonumber(pipe:read('*l'))
    pipe:close()
    return assert(pid, 'Cannot start background process')
end

function Process:start(command, log_path, input_path, opts)
    self:check_interrupted()
    opts = opts or {}
    if not fiber_runtime.in_fiber() then
        local input_fd = open_input_fd(input_path)
        local acquired, gate_token = pcall(acquire_launch_gate, self.state, false)
        if not acquired then posix.close(input_fd); error(gate_token, 0) end
        local leases, pid, record
        local input_inheritable = false
        local prepared, prepare_err = pcall(function()
            leases = validate_leases(opts.inherit_fds)
            assert_proc_supported()
            for _, lease in ipairs(leases) do auth.set_lease_inheritable(lease, true) end
            set_fd_cloexec(input_fd, false)
            input_inheritable = true
            pid = legacy_start(command, log_path, input_fd)
            set_fd_cloexec(input_fd, true)
            input_inheritable = false
        end)
        if pid then
            record = { pid = pid, pgid = pid, status = 'provisional' }
            self.legacy[pid] = record
            managed_active = managed_active + 1
        end
        local captured, capture_err = false, nil
        if record then
            captured, capture_err = pcall(function() record.identity = capture_group_identity(pid, true) end)
        end
        local input_restored, input_restore_err = true, nil
        if input_inheritable then
            input_restored, input_restore_err = pcall(set_fd_cloexec, input_fd, true)
            input_inheritable = false
        end
        local retired, retire_err = pcall(function() retire_leases(leases) end)
        local input_closed, input_close_err = posix.close(input_fd)
        if not input_restored or not input_closed then
            poison_launch_gate(input_restore_err or input_close_err or 'Legacy input descriptor cleanup failed')
        end
        release_launch_gate(gate_token)
        if prepared and captured and input_restored and retired and input_closed then
            record.status = 'active'
            return pid
        end

        local errors = {}
        if not prepared then errors[#errors + 1] = tostring(prepare_err) end
        if record and not captured then errors[#errors + 1] = tostring(capture_err) end
        if not input_restored then errors[#errors + 1] = tostring(input_restore_err) end
        if not input_closed then errors[#errors + 1] = tostring(input_close_err) end
        if not retired then errors[#errors + 1] = tostring(retire_err) end
        if record then
            local contained, contain_err = pcall(function()
                if not record.identity then
                    local status, zombies, detail = M.classify_group(record.pgid)
                    if status ~= 'ABSENT' and status ~= 'ZOMBIES_ONLY' then
                        error(('Provisional process containment is %s%s'):format(
                            status, detail and (': ' .. detail) or ''), 0)
                    end
                    record.containment, record.zombies = status, zombies
                else
                    self:_stop_legacy_record(record, 2)
                end
                self.legacy[pid] = nil
                self.tombstone[pid] = true
                managed_active = managed_active - 1
            end)
            if not contained then
                poison_launch_gate(contain_err)
                errors[#errors + 1] = 'Provisional process retained: ' .. tostring(contain_err)
            end
        end
        error(table.concat(errors, '\n'), 0)
    end
    local handle = self:_launch(command, { log_path = log_path, input_path = input_path, timeout = 40,
        inherit_fds = opts.inherit_fds }, true)
    return assert(handle.pgid)
end

function Process:_stop_legacy_record(record, grace)
    local pid = record.pgid
    assert(record.identity, 'Legacy process identity was not captured')
    local should_signal = validate_delayed_identity(record.identity)
    if should_signal and group_exists(pid) then signal_group(pid, signals.SIGTERM or 15) end
    local deadline = M.now() + (grace or 2)
    while group_exists(pid) and M.now() < deadline do
        clock.nanosleep({ tv_sec = 0, tv_nsec = 100000000 })
    end
    if should_signal and group_exists(pid) then signal_group(pid, signals.SIGKILL or 9) end
    local status, zombies = wait_for_containment(pid, function()
        clock.nanosleep({ tv_sec = 0, tv_nsec = 50000000 })
    end)
    record.containment, record.zombies = status, zombies
end

function Process:stop(pid, grace)
    assert(type(pid) == 'number' and pid == math.floor(pid) and pid > 1, 'Invalid owned process ID')
    if self.tombstone[pid] then return end
    local handle = self.by_pid[pid]
    if handle then
        local ok, err = pcall(function() self:_shutdown_group(handle, grace) end)
        if not ok then error(err, 0) end
        self:_close_handle(handle)
        return
    end
    local record = self.legacy[pid]
    assert(record, 'Unknown or unowned process ID: ' .. pid)
    self:_stop_legacy_record(record, grace)
    self.legacy[pid] = nil
    self.tombstone[pid] = true
    managed_active = managed_active - 1
end

function Process:stop_all()
    local handles = {}
    for handle in pairs(self.active) do handles[#handles + 1] = handle end
    local legacy = {}
    for pid in pairs(self.legacy) do legacy[#legacy + 1] = pid end
    local errors = {}
    for _, handle in ipairs(handles) do
        local ok, err = pcall(function()
            if not handle.identity then self:_shutdown_unidentified(handle, false)
            elseif handle.pgid then self:_shutdown_group(handle, 2)
            else fiber_runtime.get().fibers.perform(handle.command:shutdown_op(2)) end
            self:_close_handle(handle)
        end)
        if not ok then errors[#errors + 1] = tostring(err) end
    end
    for _, pid in ipairs(legacy) do
        local ok, err = pcall(function() self:stop(pid, 2) end)
        if not ok then errors[#errors + 1] = tostring(err) end
    end
    assert(#errors == 0, table.concat(errors, '\n'))
end

return M
