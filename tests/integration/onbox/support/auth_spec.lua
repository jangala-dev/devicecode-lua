local posix = require 'posix'
local fcntl = require 'posix.fcntl'
local poll = require 'posix.poll'
local termio = require 'posix.termio'
local time = require 'posix.time'
local auth = require 'onbox.support.auth'
local process = require 'onbox.support.process'
local runner = require 'onbox.support.runner'

local tests = {}
local dummy_password = "dummy p'ass $word;" .. string.char(96) .. 'safe' .. string.char(96) .. '!'

---@param value string
---@return string
local function quote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

---@param fd integer
---@param timeout integer
---@return boolean
local function readable(fd, timeout)
    local fds = { [fd] = { events = { IN = true } } }
    return assert(poll.poll(fds, timeout)) > 0
end

---@param signal integer? Cancel the prompt instead of entering the dummy password.
---@return nil
local function check_prompt(signal)
    io.stdout:flush()
    local master, slave = assert(posix.openpty())
    local original = assert(termio.tcgetattr(slave))
    local reader, writer = assert(posix.pipe())
    local pid = assert(posix.fork())
    if pid == 0 then
        posix.close(master)
        posix.close(reader)
        local ok, result = pcall(auth.prompt_fd, slave, 'example.invalid')
        local passed = signal and not ok and tostring(result):find('interrupted', 1, true)
            or (not signal and ok and result == dummy_password)
        posix.write(writer, passed and 'pass' or 'fail')
        posix._exit(passed and 0 or 1)
    end
    posix.close(writer)
    local ok, err = pcall(function()
        assert(readable(master, 2000), 'Password prompt did not appear')
        local transcript = assert(posix.read(master, 4096))
        assert(transcript:find('SSH password for example.invalid:', 1, true))
        local hidden = assert(termio.tcgetattr(slave))
        assert(require('bit').band(hidden.lflag, termio.ECHO + termio.ECHONL) == 0, 'Password echo is enabled')
        if signal then assert(posix.kill(pid, signal))
        else assert(posix.write(master, dummy_password .. '\n')) end
        assert(readable(reader, 2000), 'Password prompt did not finish')
        assert(posix.read(reader, 4) == 'pass', 'Password prompt child failed')
        while readable(master, 30) do transcript = transcript .. assert(posix.read(master, 4096)) end
        assert(not transcript:find(dummy_password, 1, true), 'Password was echoed')
        assert(assert(termio.tcgetattr(slave)).lflag == original.lflag, 'Terminal flags were not restored')
        local _, reason, code = posix.wait(pid)
        assert(reason == 'exited' and code == 0, 'Password prompt child failed')
        pid = nil
    end)
    if pid then posix.kill(pid, posix.SIGKILL); posix.wait(pid) end
    posix.close(master)
    posix.close(slave)
    posix.close(reader)
    assert(ok, err)
end

---@return nil
function tests.prompt_hides_password_and_restores_echo()
    check_prompt()
end

---@return nil
function tests.prompt_restores_echo_when_interrupted_or_suspended()
    for _, sig in ipairs({ posix.SIGINT, posix.SIGTERM, posix.SIGTSTP }) do check_prompt(sig) end
end

---@return nil
function tests.prompt_refuses_non_terminal_input()
    local reader, writer = assert(posix.pipe())
    local ok, err = pcall(auth.prompt_fd, reader, 'example.invalid')
    posix.close(reader)
    posix.close(writer)
    assert(not ok and tostring(err):find('interactive terminal', 1, true))
end

---@return nil
function tests.password_pipe_closes_on_success_and_failure()
    for _, fail in ipairs({ false, true }) do
        local descriptor
        local lease
        local ok, result = pcall(auth.with_password_fd, dummy_password, function(fd, supplied_lease)
            lease = supplied_lease
            descriptor = fd
            assert(not auth.lease_is_inheritable(lease), 'Password descriptor must default to CLOEXEC')
            local executed, execute_err = pcall(process.execute, 'true')
            assert(not executed and tostring(execute_err):find('forbidden', 1, true),
                'Blocking execute was allowed while a credential lease was active')
            assert(posix.read(fd, 4096) == dummy_password .. '\n', 'Password pipe contained incorrect data')
            if fail then error('callback failed') end
            return 'complete'
        end)
        assert(fcntl.fcntl(descriptor, fcntl.F_GETFD) == nil, 'Password descriptor leaked')
        local live = pcall(auth.lease_fd, lease)
        assert(not live, 'Credential lease remained live after callback')
        assert(ok == not fail)
        if not fail then assert(result == 'complete') end
    end
end

---@return nil
function tests.manual_password_auth_preserves_upload_stdin_and_background_auth()
    local temp = assert(posix.mkdtemp('/tmp/onbox-auth-XXXXXX'))
    local original_path = assert(os.getenv('PATH'))
    local bin = temp .. '/bin'
    assert(posix.mkdir(bin, 'rwx------'))
    local shim = assert(io.open(bin .. '/sshpass', 'w'))
    shim:write([[#!/bin/sh
test "$1" = "-d" || exit 2
export ONBOX_TEST_PASSWORD_FD="$2"
shift 2
exec "$@"
]])
    shim:close()
    assert(posix.chmod(bin .. '/sshpass', 'rwx------'))
    assert(posix.setenv('PATH', bin .. ':' .. original_path, true))
    local here = assert(posix.realpath(arg[0])):match('^(.*)/[^/]+$')
    local repo = assert(here:match('^(.*)/tests/integration/onbox/support$'))
    local box = runner.new(runner.parse_args({ '--ask-pass', '--artifacts', temp .. '/logs' }, repo, here),
        dummy_password)
    local background_pid
    local ok, err = pcall(function()
        local script = assert(io.open(temp .. '/fake_ssh.lua', 'w'))
        script:write([[
local posix = require 'posix'
local bit = require 'bit'
local termio = require 'posix.termio'
-- Delay authentication so the background launcher has already closed its pipe copy.
os.execute('sleep 0.1')
local fd = assert(tonumber(os.getenv('ONBOX_TEST_PASSWORD_FD')))
local line = assert(posix.read(fd, 4096))
assert(line:sub(1, -2) == ]] .. string.format('%q', dummy_password) .. [[, 'Incorrect test password')
io.stdout:write('authenticated\n', io.stdin:read('*a'))
]])
        script:close()
        box.ssh.command = 'luajit ' .. quote(temp .. '/fake_ssh.lua')
        for _, data in ipairs({ 'first upload', 'second upload' }) do
            local result = box.ssh:run('unused', { data = data, timeout = 5 })
            assert(result.stdout == 'authenticated\n' .. data, 'Upload stdin was consumed by authentication')
        end
        box.ssh:with_command(function(command)
            assert(not command:find(dummy_password, 1, true), 'Password appeared in command arguments')
        end)
        background_pid = box.ssh:start('unused', temp .. '/logs/background.out')
        local output = ''
        for _ = 1, 150 do
            local file = io.open(temp .. '/logs/background.out', 'r')
            if file then output = file:read('*a'); file:close() end
            if output == 'authenticated\n' then break end
            time.nanosleep({ tv_sec = 0, tv_nsec = 20000000 })
        end
        assert(output == 'authenticated\n', 'Background authentication failed')
        box.process:stop(background_pid)
        background_pid = nil
        for name in posix.files(box.artifacts) do
            if name ~= '.' and name ~= '..' then
                local file = assert(io.open(box.artifacts .. '/' .. name, 'r'))
                local content = file:read('*a')
                file:close()
                assert(not content:find(dummy_password, 1, true), 'Password appeared in test artifacts')
            end
        end
    end)
    posix.setenv('PATH', original_path, true)
    if not ok and background_pid then posix.kill(-background_pid, posix.SIGTERM) end
    for name in posix.files(box.artifacts) do
        if name ~= '.' and name ~= '..' then os.remove(box.artifacts .. '/' .. name) end
    end
    posix.rmdir(box.artifacts)
    os.remove(temp .. '/fake_ssh.lua')
    os.remove(bin .. '/sshpass')
    posix.rmdir(bin)
    posix.rmdir(temp)
    assert(ok, err)
end

return tests
