-- fibers/io/exec_backend/nixio.lua
--
-- Nixio-based exec backend using a per-command “reaper” process and
-- a sentinel pipe for completion notifications.
--
-- Topology per command:
--   parent
--     ├─ reaper (Lua, this module)
--     │    └─ child (exec'ed programme)
--     └─ sentinel_r (read end of status pipe)
--
-- Protocol on the sentinel pipe:
--   - reaper writes:   "pid <child_pid>\n"
--   - later writes one of:
--         "exited <code>\n"
--         "signaled <signal>\n"
--         "failed <message>\n"
--
-- Parent uses poller to wait for sentinel_r readability; when data
-- arrives, it parses lines and updates backend state.
--
-- Uses nixio File objects as fds throughout.

local core    = require 'fibers.io.exec_backend.core'
local poller  = require 'fibers.io.poller'
local runtime = require 'fibers.runtime'
local file_io = require 'fibers.io.file'
local stdio   = require 'fibers.io.exec_backend.stdio'

local ok, nixio = pcall(require, 'nixio')
if not ok or not nixio then
	return { is_supported = function () return false end }
end

local const = nixio.const or {}

local unpack = rawget(table, 'unpack') or _G.unpack

local DEV_NULL = '/dev/null'

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------

local function errno_msg(prefix)
	local eno  = nixio.errno()
	local estr = (nixio.strerror and nixio.strerror(eno)) or ('errno ' .. tostring(eno))
	if prefix then
		return ('%s: %s'):format(prefix, estr)
	end
	return estr
end

local function close_fd(f)
	if f and f.close then
		pcall(function () f:close() end)
	end
end

----------------------------------------------------------------------
-- Stdio integration for exec_backend.stdio
----------------------------------------------------------------------

--- Open /dev/null for input or output (child side).
---@param is_output boolean
---@return any fd, string|nil err
local function open_dev_null(is_output)
	local mode   = is_output and 'w' or 'r'
	local f, err = nixio.open(DEV_NULL, mode)
	if not f then
		return nil, err or errno_msg('open ' .. DEV_NULL)
	end
	return f, nil
end

--- Create a pipe (child <-> parent).
---@return any rd, any wr, string|nil err
local function make_pipe()
	local rd, wr = nixio.pipe()
	if not rd or not wr then
		return nil, nil, errno_msg('pipe')
	end
	return rd, wr, nil
end

--- We rely on explicit close() in child/reaper instead of close-on-exec.
---@param _ any
---@return boolean, string|nil
local function set_cloexec(_)
	return true, nil
end

--- Wrap a parent-side fd into a Stream.
---@param role "stdin"|"stdout"|"stderr"
---@param fd any  -- nixio File
---@return Stream
local function open_stream(role, fd)
	if role == 'stdin' then
		return file_io.fdopen(fd, 'w')
	else
		return file_io.fdopen(fd, 'r')
	end
end

----------------------------------------------------------------------
-- Child exec path (runs in the real child process)
----------------------------------------------------------------------

--- Duplicate src onto dest_fd (0/1/2) using nixio.dup with nixio.stdin/stdout/stderr.
---@param src any      -- nixio File
---@param dest_fd integer
local function setup_child_fd(src, dest_fd)
	if not src then
		return
	end

	local curfd = src:fileno()
	if curfd == dest_fd then
		return
	end

	local dest
	if dest_fd == 0 then
		dest = nixio.stdin
	elseif dest_fd == 1 then
		dest = nixio.stdout
	elseif dest_fd == 2 then
		dest = nixio.stderr
	else
		-- exec_backend.stdio only uses 0/1/2.
		os.exit(127)
	end

	local dup, _ = nixio.dup(src, dest)
	if not dup then
		os.exit(127)
	end
end

local function apply_child_env(env)
	for name, value in pairs(env) do
		if value == nil then
			nixio.setenv(name) -- unset
		else
			local ok1, _ = nixio.setenv(name, tostring(value))
			if not ok1 then
				os.exit(127)
			end
		end
	end
end

---@param child_spec table  -- child-facing spec with *fd fields
---@param child_only table<any, boolean>|nil
---@param parent_fds table<string, any|nil>|nil
---@param sentinel_w any|nil  -- nixio File, closed in child
local function child_exec(child_spec, child_only, parent_fds, sentinel_w)
	if sentinel_w then
		close_fd(sentinel_w)
	end

	if child_spec.cwd then
		local ok1, _ = nixio.chdir(child_spec.cwd)
		if not ok1 then
			os.exit(127)
		end
	end

	if child_spec.flags and child_spec.flags.setsid then
		local sid, _ = nixio.setsid()
		if not sid then
			os.exit(127)
		end
	end

	if child_spec.env then
		apply_child_env(child_spec.env)
	end

	setup_child_fd(child_spec.stdin_fd, 0)
	setup_child_fd(child_spec.stdout_fd, 1)
	setup_child_fd(child_spec.stderr_fd, 2)

	stdio.close_child_only(child_only, close_fd)
	stdio.close_parent_fds(parent_fds, close_fd)

	local argv = child_spec.argv
	local prog = assert(argv[1], 'child_exec: argv[1] must be non-nil')

	-- execp(executable, ...) sets argv[0] automatically.
	local n = #argv
	if n == 1 then
		nixio.execp(prog)
	else
		local args = {}
		for i = 2, n do
			args[#args + 1] = argv[i]
		end
		nixio.execp(prog, unpack(args))
	end

	os.exit(127)
end

----------------------------------------------------------------------
-- Backend state helpers and parsing
----------------------------------------------------------------------

---@class NixioExecState
---@field reaper_pid integer        -- pid of the reaper process
---@field pid integer|nil           -- for introspection; updated to child pid when known
---@field child_pid integer|nil     -- pid of the real exec'ed child
---@field sentinel any              -- nixio File (read end)
---@field exited boolean
---@field code integer|nil
---@field signal integer|nil
---@field err string|nil
---@field _buf string|nil
---@field _have_status boolean|nil
---@field _reaper_reaped boolean|nil

local function parse_status_line_into_state(line, state)
	line = line:gsub('\r', '')
	local tag, rest = line:match('^(%S+)%s*(.*)$')
	if not tag then
		state.err          = state.err or 'invalid status line from reaper'
		state.exited       = true
		state._have_status = true
		return
	end

	if tag == 'pid' then
		local cpid = tonumber(rest)
		if cpid then
			state.child_pid = cpid
			state.pid       = state.pid or cpid
		end
		return
	elseif tag == 'exited' then
		local code         = tonumber(rest) or 0
		state.code         = code
		state.signal       = nil
		state.err          = state.err or nil
		state.exited       = true
		state._have_status = true
		return
	elseif tag == 'signaled' or tag == 'signalled' then
		local sig          = tonumber(rest) or 0
		state.code         = nil
		state.signal       = sig
		state.err          = state.err or nil
		state.exited       = true
		state._have_status = true
		return
	elseif tag == 'failed' then
		local msg          = rest ~= '' and rest or 'exec backend failed'
		state.code         = nil
		state.signal       = nil
		state.err          = msg
		state.exited       = true
		state._have_status = true
		return
	else
		state.err          = state.err or ("unknown status tag '" .. tostring(tag) .. "'")
		state.exited       = true
		state._have_status = true
		return
	end
end

local function reap_reaper(state)
	if state._reaper_reaped or not state.reaper_pid then
		return
	end
	local pid, _, _ = nixio.waitpid(state.reaper_pid, 'nohang')
	if pid and pid ~= 0 then
		state._reaper_reaped = true
	end
end

----------------------------------------------------------------------
-- Reaper process path
----------------------------------------------------------------------

--- Run in the per-command reaper process.
---@param child_spec table
---@param child_only table<any, boolean>|nil
---@param parent_fds table<string, any|nil>|nil
---@param sentinel_r any        -- nixio File (parent-side read end, close here)
---@param sentinel_w any        -- nixio File (reaper-side writer)
local function reaper_main(child_spec, child_only, parent_fds, sentinel_r, sentinel_w)
	-- Reaper does not need parent pipe ends or parent's sentinel read end.
	stdio.close_parent_fds(parent_fds, close_fd)
	close_fd(sentinel_r)

	-- Fork the real child.
	local child_pid, err = nixio.fork()
	if not child_pid then
		if sentinel_w then
			sentinel_w:write('failed ' .. (err or errno_msg('fork')) .. '\n')
			close_fd(sentinel_w)
		end
		os.exit(127)
	end

	if child_pid == 0 then
		-- In the real child.
		child_exec(child_spec, child_only, parent_fds, sentinel_w)
		os.exit(127)
	end

	-- In the reaper.
	stdio.close_child_only(child_only, close_fd)

	-- Tell parent the real child pid.
	if sentinel_w then
		pcall(function ()
			sentinel_w:write(('pid %d\n'):format(child_pid))
		end)
	end

	-- Wait for the real child to exit.
	local pid, how, what
	while true do
		pid, how, what = nixio.waitpid(child_pid)
		if pid ~= nil then
			break
		end
		local eno = nixio.errno()
		if eno ~= const.EINTR then
			break
		end
	end

	local line
	if not pid then
		line = 'failed ' .. errno_msg('waitpid') .. '\n'
	else
		if how == 'exited' then
			local code = tonumber(what) or 0
			line = ('exited %d\n'):format(code)
		elseif how == 'signaled' or how == 'signalled' then
			local sig = tonumber(what) or 0
			line = ('signaled %d\n'):format(sig)
		else
			line = ('failed unexpected %s %s\n'):format(tostring(how), tostring(what))
		end
	end

	if sentinel_w then
		pcall(function ()
			sentinel_w:write(line)
			sentinel_w:close()
		end)
	end

	os.exit(0)
end

----------------------------------------------------------------------
-- Polling of sentinel in the parent
----------------------------------------------------------------------

--- Non-blocking poll of the sentinel pipe.
---@param state NixioExecState
---@return boolean done, integer|nil code, integer|nil signal, string|nil err
local function poll_state(state)
	if state.exited then
		return true, state.code, state.signal, state.err
	end

	if not state.sentinel then
		-- Sentinel has gone away without a status line.
		if not state._have_status then
			state.exited = true
			state.err    = state.err or 'reaper sentinel closed'
		end
		reap_reaper(state)
		return true, state.code, state.signal, state.err
	end

	local bufsize = const.buffersize or 256

	while true do
		local chunk, _ = state.sentinel:read(bufsize)

		if not chunk then
			local eno = nixio.errno()
			if eno == const.EAGAIN or eno == const.EWOULDBLOCK or eno == const.EINTR then
				-- Nothing available right now.
				break
			end

			-- Hard error; treat as completion if we do not yet have a status.
			close_fd(state.sentinel)
			state.sentinel = nil
			if not state._have_status then
				state.exited = true
				state.err    = state.err or 'reaper sentinel closed'
			end
			reap_reaper(state)
			break
		end

		if #chunk == 0 then
			-- EOF: writer closed pipe.
			close_fd(state.sentinel)
			state.sentinel = nil
			if not state._have_status then
				state.exited = true
				state.err    = state.err or 'reaper sentinel closed'
			end
			reap_reaper(state)
			break
		end

		state._buf = (state._buf or '') .. chunk

		while true do
			local line, rest = state._buf:match('^(.-)\n(.*)$')
			if not line then
				break
			end
			state._buf = rest
			parse_status_line_into_state(line, state)
		end

		if state.exited then
			close_fd(state.sentinel)
			state.sentinel = nil
			reap_reaper(state)
			break
		end
	end

	if state.exited then
		return true, state.code, state.signal, state.err
	else
		return false, nil, nil, nil
	end
end

----------------------------------------------------------------------
-- exec_backend.core ops
----------------------------------------------------------------------

--- spawn(spec) -> state, streams, err
---@param spec ExecProcSpec
---@return NixioExecState|nil state,{stdin:Stream|nil,stdout:Stream|nil,stderr:Stream|nil}|nil streams,string|nil err
local function spawn(spec)
	assert(type(spec) == 'table', 'ExecBackend.spawn: spec must be a table')
	assert(type(spec.argv) == 'table' and spec.argv[1],
		'ExecBackend.spawn: spec.argv must be a non-empty array')

	local child_spec, child_only, parent_fds, cfg_err =
		stdio.build_child_stdio(spec, open_dev_null, make_pipe, set_cloexec, close_fd)
	if not child_spec then
		return nil, nil, cfg_err
	end

	-- Sentinel pipe: reaper writes, parent reads.
	local sentinel_r, sentinel_w = nixio.pipe()
	if not sentinel_r or not sentinel_w then
		stdio.close_child_only(child_only, close_fd)
		stdio.close_parent_fds(parent_fds, close_fd)
		return nil, nil, errno_msg('pipe (sentinel)')
	end

	-- We will use the sentinel in blocking mode temporarily for a
	-- handshake to learn the real child pid, then switch to non-blocking.
	sentinel_r:setblocking(true)

	-- Fork the per-command reaper.
	local reaper_pid, ferr = nixio.fork()
	if not reaper_pid then
		stdio.close_child_only(child_only, close_fd)
		stdio.close_parent_fds(parent_fds, close_fd)
		close_fd(sentinel_r)
		close_fd(sentinel_w)
		return nil, nil, ferr or errno_msg('fork (reaper)')
	end

	if reaper_pid == 0 then
		reaper_main(child_spec, child_only, parent_fds, sentinel_r, sentinel_w)
		os.exit(127)
	end

	-- Parent.
	stdio.close_child_only(child_only, close_fd)
	close_fd(sentinel_w)

	local state = {
		reaper_pid     = reaper_pid,
		pid            = reaper_pid, -- will be updated once child pid is known
		child_pid      = nil,
		sentinel       = sentinel_r,
		exited         = false,
		code           = nil,
		signal         = nil,
		err            = nil,
		_buf           = '',
		_have_status   = false,
		_reaper_reaped = false,
	}

	-- Handshake: read sentinel until we have seen a pid line and/or a
	-- terminal status. This guarantees child_pid is known before any
	-- external code can attempt to send signals.
	local bufsize = const.buffersize or 256

	while not state.child_pid and not state._have_status do
		local chunk, rerr = sentinel_r:read(bufsize)
		if not chunk then
			close_fd(sentinel_r)
			state.sentinel = nil
			return nil, nil, rerr or errno_msg('sentinel handshake read')
		end
		if #chunk == 0 then
			close_fd(sentinel_r)
			state.sentinel = nil
			return nil, nil, 'sentinel closed during handshake'
		end

		state._buf = (state._buf or '') .. chunk

		while true do
			local line, rest = state._buf:match('^(.-)\n(.*)$')
			if not line then
				break
			end
			state._buf = rest
			parse_status_line_into_state(line, state)
		end
	end

	-- Switch sentinel to non-blocking for normal event-loop use.
	sentinel_r:setblocking(false)

	local streams = stdio.build_parent_streams(parent_fds, open_stream)

	return state, streams, nil
end

--- poll(state) -> done, code, signal, err
local function poll_backend(state)
	return poll_state(state)
end

--- register_wait(state, task, suspension, leaf_wrap) -> WaitToken
local function register_wait(state, task, _, _)
	if not state.sentinel then
		-- No fd to wait on; reschedule once so that step() can see terminal state.
		local sched = runtime.current_scheduler
		if sched and sched.schedule then
			sched:schedule(task)
		end
		return { unlink = function () return false end }
	end

	return poller.get():wait(state.sentinel, 'rd', task)
end

--- Send a signal to the real child.
---@param state NixioExecState
---@param sig integer|nil
---@return boolean ok, string|nil err
local function send_signal(state, sig)
	sig = sig or const.SIGTERM or 15

	-- If already finished, nothing to do.
	if state.exited then
		return true, nil
	end

	-- Process any queued sentinel data (should not normally change
	-- child_pid, as the handshake has already seen the pid line).
	poll_state(state)

	if state.exited then
		return true, nil
	end

	local target = state.child_pid
	if not target then
		-- As a last resort, fall back to the reaper pid; this should be
		-- unreachable in normal operation because the handshake ensures
		-- child_pid is known.
		target = state.reaper_pid or state.pid
	end
	if not target then
		return false, 'no child or reaper pid available'
	end

	local ok1, err = nixio.kill(target, sig)
	if not ok1 then
		return false, err or errno_msg('kill')
	end
	return true, nil
end

local function terminate(state)
	return send_signal(state, const.SIGTERM or 15)
end

local function kill_proc(state)
	return send_signal(state, const.SIGKILL or 9)
end

local function close_state(state)
	close_fd(state.sentinel)
	state.sentinel = nil
	reap_reaper(state)
	return true, nil
end

local function is_supported()
	return type(nixio) == 'table'
		and type(nixio.fork) == 'function'
		and type(nixio.waitpid) == 'function'
		and type(nixio.execp) == 'function'
		and type(nixio.pipe) == 'function'
		and type(nixio.open) == 'function'
end

local ops = {
	spawn         = spawn,
	poll          = poll_backend,
	register_wait = register_wait,
	send_signal   = send_signal,
	terminate     = terminate,
	kill          = kill_proc,
	close         = close_state,
	is_supported  = is_supported,
}

return core.build_backend(ops)
