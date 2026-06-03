-- fibers/io/exec_backend/pidfd.lua
--
-- Linux pidfd-based process backend.
-- Uses fork + execvp + raw pidfd_open syscall + non-blocking waitpid.
--
---@module 'fibers.io.exec_backend.pidfd'

local core    = require 'fibers.io.exec_backend.core'
local poller  = require 'fibers.io.poller'
local runtime = require 'fibers.runtime'
local ffi_c   = require 'fibers.utils.ffi_compat'
local file_io = require 'fibers.io.file'
local stdio   = require 'fibers.io.exec_backend.stdio'

local ffi       = ffi_c.ffi
local C         = ffi_c.C
local toint     = ffi_c.tonumber
local get_errno = ffi_c.errno
local DEV_NULL  = '/dev/null'

local bit = rawget(_G, 'bit') or require 'bit32'

----------------------------------------------------------------------
-- FFI / CFFI availability
----------------------------------------------------------------------

if not (ffi_c.is_supported and ffi_c.is_supported()) then
	return { is_supported = function () return false end }
end

----------------------------------------------------------------------
-- FFI declarations and constants
----------------------------------------------------------------------

local jit = rawget(_G, "jit")
local ARCH = ffi.arch or ((jit and jit.arch) or 'x64')

ffi.cdef [[
  typedef int pid_t;
  typedef unsigned int uint;

  long syscall(long number, ...);

  pid_t fork(void);
  void  _exit(int status);
  int   chdir(const char *path);
  int   setenv(const char *name, const char *value, int overwrite);
  pid_t setsid(void);
  int   execvp(const char *file, char *const argv[]);

  int   kill(pid_t pid, int sig);
  int   close(int fd);

  int   fcntl(int fd, int cmd, ...);

  pid_t waitpid(pid_t pid, int *wstatus, int options);
  pid_t getpid(void);

  int   dup2(int oldfd, int newfd);

  int   pipe(int pipefd[2]);
  int   open(const char *pathname, int flags, int mode);

  char *strerror(int errnum);
]]

-- Raw syscall number for pidfd_open.
local SYS_pidfd_open = 434 -- Linux generic
if ARCH == 'mips' or ARCH == 'mipsel' then
	-- See https://www.linux-mips.org/wiki/Syscall
	SYS_pidfd_open = 4000 + 434
end

-- fcntl constants (Linux)
local F_GETFL    = 3
local F_SETFL    = 4
local F_GETFD    = 1
local F_SETFD    = 2
local O_NONBLOCK = 0x00000800
local FD_CLOEXEC = 1

-- Minimal open() flags we need here.
local O_RDONLY = 0
local O_WRONLY = 1

-- wait/errno constants (Linux)
local WNOHANG = 1

local EINTR  = 4
local ESRCH  = 3
local ECHILD = 10
local ENOSYS = 38

-- Signals (Linux values).
local SIGTERM = 15
local SIGKILL = 9

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------

local function strerror(e)
	local s = C.strerror(e)
	if s == nil then
		return 'errno ' .. tostring(e)
	end
	return ffi.string(s)
end

local function errno_msg(prefix, err, eno)
	if err and err ~= '' then
		return err
	end
	if eno then
		return ('%s (errno %d)'):format(prefix, eno)
	end
	return prefix
end

-- In the child we must not return to Lua on fatal errors.
local function must_child(ok)
	if not ok then
		C._exit(127)
	end
end

----------------------------------------------------------------------
-- Raw pidfd_open syscall (musl/glibc-independent)
----------------------------------------------------------------------

local function pidfd_open_raw(pid, flags)
	pid   = ffi.new('pid_t', pid)
	flags = ffi.new('uint', flags or 0)

	local fd = toint(C.syscall(SYS_pidfd_open, pid, flags))
	if fd == -1 then
		local e = get_errno()
		return nil, strerror(e), e
	end
	return fd, nil, nil
end

----------------------------------------------------------------------
-- fcntl helpers: set_nonblock / set_cloexec
----------------------------------------------------------------------

local getfl_fp = ffi.cast('int (*)(int, int)', C.fcntl)
local setfl_fp = ffi.cast('int (*)(int, int, int)', C.fcntl)

local function set_nonblock(fd)
	local before = assert(toint(getfl_fp(fd, F_GETFL)))
	if before < 0 then
		local e = get_errno()
		return false, ('F_GETFL failed: %s'):format(strerror(e)), e
	end

	local new_flags = bit.bor(before, O_NONBLOCK)
	local rc        = toint(setfl_fp(fd, F_SETFL, new_flags))
	if rc < 0 then
		local e = get_errno()
		return false, ('F_SETFL failed: %s'):format(strerror(e)), e
	end

	-- Optional sanity check.
	local after = assert(toint(getfl_fp(fd, F_GETFL)))
	if after < 0 then
		local e = get_errno()
		return false, ('F_GETFL (post) failed: %s'):format(strerror(e)), e
	end

	if bit.band(after, O_NONBLOCK) == 0 then
		return false,
			('set_nonblock: O_NONBLOCK not set after F_SETFL; before=0x%x after=0x%x')
			:format(before, after),
			nil
	end

	return true, nil, nil
end

local getfd_fp = ffi.cast('int (*)(int, int)', C.fcntl)
local setfd_fp = ffi.cast('int (*)(int, int, int)', C.fcntl)

local function set_cloexec(fd)
	local before = assert(toint(getfd_fp(fd, F_GETFD)))
	if before < 0 then
		local e = get_errno()
		return false, ('F_GETFD failed: %s'):format(strerror(e)), e
	end

	local new_flags = bit.bor(before, FD_CLOEXEC)
	local rc        = toint(setfd_fp(fd, F_SETFD, new_flags))
	if rc < 0 then
		local e = get_errno()
		return false, ('F_SETFD failed: %s'):format(strerror(e)), e
	end

	return true, nil, nil
end

----------------------------------------------------------------------
-- waitpid helpers (status inspection)
----------------------------------------------------------------------

local function WIFEXITED(status)
	return bit.band(status, 0x7f) == 0
end

local function WEXITSTATUS(status)
	return bit.rshift(status, 8)
end

local function WIFSIGNALED(status)
	local term = bit.band(status, 0x7f)
	return term ~= 0 and term ~= 0x7f
end

local function WTERMSIG(status)
	return bit.band(status, 0x7f)
end

----------------------------------------------------------------------
-- Child-side helpers: argv/env/fd setup
----------------------------------------------------------------------

local function build_argv_c(argv)
	local n     = #argv
	local cargv = ffi.new('char *[?]', n + 1)

	for i = 1, n do
		local s  = assert(argv[i], 'argv must not contain nil')
		local cs = ffi.new('char[?]', #s + 1)
		ffi.copy(cs, s)
		cargv[i - 1] = cs
	end
	cargv[n] = nil

	return cargv
end

local function setup_child_fd(src_fd, dest_fd)
	if not src_fd or src_fd == dest_fd then
		return
	end
	local rc = toint(C.dup2(src_fd, dest_fd))
	if rc < 0 then
		must_child(false)
	end
end

local function apply_child_env(env)
	for name, value in pairs(env) do
		local v  = value and tostring(value) or nil
		local rc = C.setenv(name, v, 1) -- value == nil clears the variable
		if rc ~= 0 then
			must_child(false)
		end
	end
end

---@param spec table  -- child-facing spec with *fd fields
local function child_exec(spec)
	if spec.cwd then
		local rc = C.chdir(spec.cwd)
		must_child(rc == 0)
	end

	if spec.flags and spec.flags.setsid then
		local rc = toint(C.setsid())
		must_child(rc ~= -1)
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
				C.close(fd)
			end
		end
	end

	local argv  = spec.argv
	local cargv = build_argv_c(argv)

	C.execvp(argv[1], cargv)

	-- If we reach here, execvp failed.
	C._exit(127)
end

----------------------------------------------------------------------
-- Backend state helpers
----------------------------------------------------------------------

---@class PidfdState
---@field pid integer
---@field pidfd integer|nil
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

--- Blocking wait used only in the error path after a failed pidfd_open.
local function wait_blocking(pid)
	local status_buf = ffi.new('int[1]')
	while true do
		local rpid = toint(C.waitpid(pid, status_buf, 0))
		if rpid == -1 then
			local e = get_errno()
			if e ~= EINTR then
				return
			end
		else
			-- Child reaped.
			return
		end
	end
end

--- Non-blocking wait on a single child.
---@param st PidfdState
---@return boolean done, integer|nil code, integer|nil signal, string|nil err
local function poll_state(st)
	if st.exited then
		return true, st.code, st.signal, st.err
	end

	local status_buf = ffi.new('int[1]')
	local rpid       = toint(C.waitpid(st.pid, status_buf, WNOHANG))

	if rpid == 0 then
		-- Still running.
		return false, nil, nil, nil
	end

	if rpid == -1 then
		local e = get_errno()
		if e == ECHILD or e == ESRCH then
			-- Child already gone or reaped elsewhere.
			finalise_state(st, nil, nil, nil, nil)
			return true, st.code, st.signal, st.err
		end
		finalise_state(st, nil, nil, nil, errno_msg('waitpid failed', nil, e))
		return true, st.code, st.signal, st.err
	end

	local status = status_buf[0]

	if WIFEXITED(status) then
		local code = WEXITSTATUS(status)
		finalise_state(st, status, code, nil, nil)
	elseif WIFSIGNALED(status) then
		local sig = WTERMSIG(status)
		finalise_state(st, status, nil, sig, nil)
	else
		-- Stopped/continued or other odd state; treat as “completed, detail unknown”.
		finalise_state(st, status, nil, nil, nil)
	end

	return true, st.code, st.signal, st.err
end

----------------------------------------------------------------------
-- Stream / stdio integration via exec_stdio
----------------------------------------------------------------------

local function open_dev_null(is_output)
	local flags = is_output and O_WRONLY or O_RDONLY
	local fd    = toint(C.open(DEV_NULL, flags, 0))
	if fd < 0 then
		local e = get_errno()
		return nil, errno_msg('failed to open ' .. DEV_NULL, nil, e)
	end
	return fd, nil
end

local function make_pipe()
	local pipefd = ffi.new('int[2]')
	local rc     = toint(C.pipe(pipefd))
	if rc ~= 0 then
		local e = get_errno()
		return nil, nil, errno_msg('pipe() failed', nil, e)
	end
	return toint(pipefd[0]), toint(pipefd[1]), nil
end

local function close_fd(fd)
	C.close(fd)
end

local function open_stream(role, fd)
	if role == 'stdin' then
		return file_io.fdopen(fd, O_WRONLY)
	else
		-- stdout / stderr
		return file_io.fdopen(fd, O_RDONLY)
	end
end

----------------------------------------------------------------------
-- Backend ops for exec_backend.core
----------------------------------------------------------------------

--- spawn(spec) -> state, streams, err
---@param spec ExecProcSpec
---@return PidfdState|nil state, {stdin:Stream|nil, stdout:Stream|nil, stderr:Stream|nil}|nil streams, string|nil err
local function spawn(spec)
	assert(type(spec) == 'table', 'ExecBackend.spawn: spec must be a table')
	assert(type(spec.argv) == 'table' and spec.argv[1],
		'ExecBackend.spawn: spec.argv must be a non-empty array')

	-- Common stdio wiring.
	local child_spec, child_only, parent_fds, cfg_err =
		stdio.build_child_stdio(spec, open_dev_null, make_pipe, set_cloexec, close_fd)
	if not child_spec then
		return nil, nil, cfg_err
	end

	-- Fork.
	local pid = toint(C.fork())
	if pid < 0 then
		local e = get_errno()
		stdio.close_child_only(child_only, close_fd)
		stdio.close_parent_fds(parent_fds, close_fd)
		return nil, nil, errno_msg('fork failed', nil, e)
	end

	if pid == 0 then
		child_exec(child_spec) -- never returns
	end

	-- Parent: child-only fds no longer needed.
	stdio.close_child_only(child_only, close_fd)

	-- Open pidfd.
	local pidfd, perr, perrno = pidfd_open_raw(pid, 0)
	if not pidfd then
		C.kill(pid, SIGKILL)
		wait_blocking(pid)
		stdio.close_parent_fds(parent_fds, close_fd)
		return nil, nil, errno_msg('pidfd_open failed', perr, perrno)
	end

	local ok, e1 = set_nonblock(pidfd)
	assert(ok, 'set_nonblock(pidfd) failed: ' .. tostring(e1))

	ok, e1 = set_cloexec(pidfd)
	assert(ok, 'set_cloexec(pidfd) failed: ' .. tostring(e1))

	local state = {
		pid    = pid,
		pidfd  = pidfd,
		exited = false,
		status = nil,
		code   = nil,
		signal = nil,
		err    = nil,
	}

	-- Common mapping from parent_fds -> Streams.
	local streams = stdio.build_parent_streams(parent_fds, open_stream)

	return state, streams, nil
end

--- poll(state) -> done, code, signal, err
local function poll(state)
	return poll_state(state)
end

--- register_wait(state, task, suspension, leaf_wrap) -> WaitToken
local function register_wait(state, task, _, _)
	if not state.pidfd then
		-- No pidfd: best-effort reschedule.
		runtime.current_scheduler:schedule(task)
		return { unlink = function () return false end }
	end
	return poller.get():wait(state.pidfd, 'rd', task)
end

local function send_signal(state, sig)
	sig = sig or SIGTERM

	local rc = toint(C.kill(state.pid, sig))
	if rc == 0 then
		return true, nil
	end

	local e = get_errno()
	if e == ESRCH then
		return true, nil
	end

	return false, errno_msg('kill failed', nil, e)
end

local function terminate(state)
	return send_signal(state, SIGTERM)
end

local function kill_proc(state)
	return send_signal(state, SIGKILL)
end

local function close_state(state)
	if state.pidfd then
		local rc = toint(C.close(state.pidfd))
		state.pidfd = nil
		if rc ~= 0 then
			local e = get_errno()
			return false, strerror(e)
		end
	end
	return true, nil
end

----------------------------------------------------------------------
-- Capability probe
----------------------------------------------------------------------

local function is_supported()
	local pid = C.getpid()
	local fd, _, eno = pidfd_open_raw(pid, 0)
	if fd then
		C.close(fd)
		return true
	end

	if eno == ENOSYS then
		return false
	end

	return true
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
