-- fibers/io/exec_backend/sigchld.lua
--
-- SIGCHLD + self-pipe process backend (luaposix only).
--
-- Portable POSIX backend for systems without pidfd_open.
-- Uses:
--   - SIGCHLD handler that writes to a non-blocking self-pipe
--   - poller watching the pipe
--   - wait(WNOHANG) per tracked child PID
--   - a Waitset to wake fibers blocked in wait_op().
--
---@module 'fibers.io.exec_backend.sigchld'

local core    = require 'fibers.io.exec_backend.core'
local unistd  = require 'posix.unistd'
local syswait = require 'posix.sys.wait'
local psignal = require 'posix.signal'
local fcntl   = require 'posix.fcntl'
local errno   = require 'posix.errno'
local stdlib  = require 'posix.stdlib'

local poller  = require 'fibers.io.poller'
local waitmod = require 'fibers.wait'
local runtime = require 'fibers.runtime'
local file_io = require 'fibers.io.file'
local stdio   = require 'fibers.io.exec_backend.stdio'

local bit = rawget(_G, 'bit') or require 'bit32'
local jit = rawget(_G, "jit")

local DEV_NULL = '/dev/null'

----------------------------------------------------------------------
-- Global state for SIGCHLD handling
----------------------------------------------------------------------

--- All children we are responsible for: pid -> SigchldState
local children = {}

--- Waiters keyed by pid: Waitset from fibers.wait.
local waiters = waitmod.new_waitset()

--- Scheduler used to reschedule waiters; populated when the reaper starts.
---@type Scheduler|nil
local child_sched

--- Self-pipe file descriptors.
---@type integer|nil
local sig_r
---@type integer|nil
local sig_w

--- Reaper task flag.
local reaper_started = false

local function errno_msg(prefix, err, eno)
	if err and err ~= '' then
		return err
	end
	if eno then
		return ('%s (errno %d)'):format(prefix, eno)
	end
	return prefix
end

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------

local function set_nonblock(fd)
	local flags, err, eno = fcntl.fcntl(fd, fcntl.F_GETFL)
	if flags == nil then
		return nil, errno_msg('fcntl(F_GETFL)', err, eno)
	end
	local newflags = bit.bor(flags, fcntl.O_NONBLOCK)
	local ok, err2, eno2 = fcntl.fcntl(fd, fcntl.F_SETFL, newflags)
	if ok == nil then
		return nil, errno_msg('fcntl(F_SETFL)', err2, eno2)
	end
	return true
end

local function set_cloexec(fd)
	local flags, err, eno = fcntl.fcntl(fd, fcntl.F_GETFD)
	if flags == nil then
		return nil, errno_msg('fcntl(F_GETFD)', err, eno)
	end
	local newflags = bit.bor(flags, fcntl.FD_CLOEXEC or 0)
	local ok, err2, eno2 = fcntl.fcntl(fd, fcntl.F_SETFD, newflags)
	if ok == nil then
		return nil, errno_msg('fcntl(F_SETFD)', err2, eno2)
	end
	return true
end

local function must_child(ok, _, _)
	if not ok or ok == 0 then
		unistd._exit(127)
	end
end

local function build_argt(argv)
	local cmd  = assert(argv[1], 'ProcSpec.argv[1] must be executable')
	local argt = {}
	argt[0]    = cmd
	for i = 2, #argv do
		argt[i - 1] = argv[i]
	end
	return cmd, argt
end

local function setup_child_fd(src_fd, dest_fd)
	if src_fd == nil or src_fd == dest_fd then
		return
	end
	local newfd, err, eno = unistd.dup2(src_fd, dest_fd)
	if not newfd then
		must_child(false, err, eno)
	end
end

local function apply_child_env(env)
	for name, value in pairs(env) do
		local ok, err, eno = stdlib.setenv(name, value and tostring(value) or nil)
		if ok == nil then
			must_child(false, err, eno)
		end
	end
end

----------------------------------------------------------------------
-- SIGCHLD self-pipe and reaper
----------------------------------------------------------------------

local function install_self_pipe_and_handler()
	if sig_r ~= nil then
		return
	end

	local r, w, err, eno = unistd.pipe()
	if not r then
		error('exec_backend.sigchld: pipe() failed: ' .. errno_msg('pipe', err, eno))
	end

	local ok1, e1 = set_nonblock(r)
	local ok2, e2 = set_nonblock(w)
	local ok3, e3 = set_cloexec(r)
	local ok4, e4 = set_cloexec(w)
	if not (ok1 and ok2 and ok3 and ok4) then
		if r then unistd.close(r) end
		if w then unistd.close(w) end
		error('exec_backend.sigchld: failed to configure self-pipe: '
			.. tostring(e1 or e2 or e3 or e4))
	end

	sig_r, sig_w = r, w

	local function handler()
		unistd.write(sig_w, 'x')
	end

	if jit and jit.off then
		jit.off(handler, true)
	end

	local flags = psignal.SA_RESTART
	local old, serr, seno
	if flags ~= nil then
		old, serr, seno = psignal.signal(psignal.SIGCHLD, handler, flags)
	else
		old, serr, seno = psignal.signal(psignal.SIGCHLD, handler)
	end
	if not old and serr then
		error('exec_backend.sigchld: signal(SIGCHLD) failed: '
			.. errno_msg('signal', serr, seno))
	end
end

----------------------------------------------------------------------
-- Backend state helpers
----------------------------------------------------------------------

---@class SigchldState
---@field pid integer
---@field exited boolean
---@field status integer|nil
---@field code integer|nil
---@field signal integer|nil
---@field err string|nil

local function finalise_state(st, status, code, signal, err)
	if st.exited then
		return
	end
	st.exited = true
	st.status = status
	st.code   = code
	st.signal = signal
	st.err    = err
end

local function poll_state(st)
	if st.exited then
		return true, st.code, st.signal, st.err
	end
	return false, nil, nil, nil
end

local function drain_self_pipe()
	if not sig_r then return end

	while true do
		local s, _, eno = unistd.read(sig_r, 4096)
		if s == nil then
			if eno == errno.EAGAIN or eno == errno.EWOULDBLOCK then
				break
			end
			break
		end
		if #s < 4096 then
			break
		end
	end
end

local function reap_known_children()
	local to_remove = {}

	for pid, st in pairs(children) do
		if st and not st.exited then
			local rpid, how, v3, err, eno = syswait.wait(pid, syswait.WNOHANG)
			if rpid == nil then
				if eno == errno.ECHILD then
					finalise_state(st, nil, nil, nil, nil)
					to_remove[#to_remove + 1] = pid
				elseif eno ~= errno.EINTR then
					finalise_state(st, nil, nil, nil, errno_msg('wait failed', err, eno))
					to_remove[#to_remove + 1] = pid
				end
			elseif how ~= 'running' then
				if how == 'exited' then
					local code = v3
					finalise_state(st, v3, code, nil, nil)
				else
					local sig = v3
					finalise_state(st, v3, nil, sig, nil)
				end
				to_remove[#to_remove + 1] = pid
			end
		end
	end

	if child_sched then
		for i = 1, #to_remove do
			local pid = to_remove[i]
			children[pid] = nil
			waiters:notify_all(pid, child_sched)
		end
	else
		for i = 1, #to_remove do
			children[to_remove[i]] = nil
		end
	end
end

---@class ReaperTask : Task
local ReaperTask = {}
ReaperTask.__index = ReaperTask

function ReaperTask:run()
	if not sig_r or not child_sched then
		return
	end

	self.armed = false
	drain_self_pipe()
	reap_known_children()

	if sig_r then
		self.armed = true
		poller.get():wait(sig_r, 'rd', self)
	end
end

local function start_reaper()
	if reaper_started then
		return
	end

	install_self_pipe_and_handler()

	reaper_started = true
	child_sched    = runtime.current_scheduler

	local task = setmetatable({}, ReaperTask)
	if not task.armed then
		task.armed = true
		poller.get():wait(sig_r, 'rd', task)
	end
end

----------------------------------------------------------------------
-- Child side exec
----------------------------------------------------------------------

---@param spec table  -- child-facing spec with *fd fields
local function child_exec(spec)
	if spec.cwd then
		local ok, err, eno = unistd.chdir(spec.cwd)
		if not ok then
			must_child(false, err, eno)
		end
	end

	if spec.flags and spec.flags.setsid then
		local res, err, eno
		if unistd.setsid then
			res, err, eno = unistd.setsid()
		elseif unistd.setpid then
			res, err, eno = unistd.setpid('s', 0)
		end
		if res == nil then
			must_child(false, err, eno)
		end
	end

	if spec.env then
		apply_child_env(spec.env)
	end

	setup_child_fd(spec.stdin_fd, 0)
	setup_child_fd(spec.stdout_fd, 1)
	setup_child_fd(spec.stderr_fd, 2)

	do
		local seen = {}
		for _, fd in ipairs { spec.stdin_fd, spec.stdout_fd, spec.stderr_fd } do
			if fd and fd > 2 and not seen[fd] then
				seen[fd] = true
				unistd.close(fd)
			end
		end
	end

	local cmd, argt = build_argt(spec.argv)
	unistd.execp(cmd, argt)
	unistd._exit(127)
end

----------------------------------------------------------------------
-- Stream / stdio integration via exec_stdio
----------------------------------------------------------------------

local function open_dev_null(is_output)
	local flags = is_output and fcntl.O_WRONLY or fcntl.O_RDONLY
	local fd, err, eno = fcntl.open(DEV_NULL, flags, 0)
	if not fd then
		return nil, errno_msg('failed to open ' .. DEV_NULL, err, eno)
	end
	return fd, nil
end

local function make_pipe()
	local rd, wr, err, eno = unistd.pipe()
	if not rd then
		return nil, nil, errno_msg('pipe() failed', err, eno)
	end
	return rd, wr, nil
end

local function close_fd(fd)
	unistd.close(fd)
end

local function open_stream(role, fd)
	if role == 'stdin' then
		return file_io.fdopen(fd, fcntl.O_WRONLY)
	else
		return file_io.fdopen(fd, fcntl.O_RDONLY)
	end
end

----------------------------------------------------------------------
-- Backend ops for exec_backend.core
----------------------------------------------------------------------

--- spawn(spec) -> state, streams, err
---@param spec ExecProcSpec
---@return SigchldState|nil state, {stdin:Stream|nil, stdout:Stream|nil, stderr:Stream|nil}|nil streams, string|nil err
local function spawn(spec)
	assert(type(spec) == 'table', 'ExecBackend.spawn: spec must be a table')
	assert(type(spec.argv) == 'table' and spec.argv[1],
		'ExecBackend.spawn: spec.argv must be a non-empty array')

	install_self_pipe_and_handler()
	start_reaper()

	-- Common stdio wiring.
	local child_spec, child_only, parent_fds, cfg_err =
		stdio.build_child_stdio(spec, open_dev_null, make_pipe, set_cloexec, close_fd)
	if not child_spec then
		return nil, nil, cfg_err
	end

	local pid, err, eno = unistd.fork()
	if not pid then
		stdio.close_child_only(child_only, close_fd)
		stdio.close_parent_fds(parent_fds, close_fd)
		return nil, nil, errno_msg('fork failed', err, eno)
	end

	if pid == 0 then
		child_exec(child_spec)
	end

	-- Parent: child-only fds no longer needed.
	stdio.close_child_only(child_only, close_fd)

	local state = {
		pid    = pid,
		exited = false,
		status = nil,
		code   = nil,
		signal = nil,
		err    = nil,
	}

	children[pid] = state

	local streams = stdio.build_parent_streams(parent_fds, open_stream)

	return state, streams, nil
end

local function poll(state)
	-- Fast path: if the child is already marked as exited, just report it.
	if state.exited then
		return true, state.code, state.signal, state.err
	end
	-- Ensure progress even when no scheduler is running
	reap_known_children()
	return poll_state(state)
end


local function register_wait(state, task, _, _)
	start_reaper()
	return waiters:add(state.pid, task)
end

local function send_signal(state, sig)
	sig = sig or psignal.SIGTERM
	local rc, err, eno = psignal.kill(state.pid, sig)
	if rc == 0 then
		return true, nil
	end
	if rc == nil and eno == errno.ESRCH then
		return true, nil
	end
	return false, errno_msg('kill failed', err, eno)
end

local function terminate(state)
	return send_signal(state, psignal.SIGTERM)
end

local function kill_proc(state)
	return send_signal(state, psignal.SIGKILL)
end

local function close_state(state)
	waiters:clear_key(state.pid)
	return true, nil
end

local function is_supported()
	if rawget(_G, 'jit') then return false end -- rare LuaJit instability
	return psignal.SIGCHLD ~= nil
end

local ops = {
	spawn         = spawn,
	poll          = poll,
	register_wait = register_wait,
	send_signal   = send_signal,
	terminate     = terminate,
	kill          = kill_proc,
	close         = close_state,
	is_supported  = is_supported,
}

return core.build_backend(ops)
