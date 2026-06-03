-- fibers/io/exec.lua - Structured process execution bound to scopes
---@module 'fibers.io.exec'

local Runtime    = require 'fibers.runtime'
local ScopeMod   = require 'fibers.scope'
local op         = require 'fibers.op'
local sleep      = require 'fibers.sleep'
local proc_mod   = require 'fibers.io.exec_backend'
local stream_mod = require 'fibers.io.stream'

local ok_probe, leak_probe = pcall(require, 'devicecode.support.leak_probe')
if not ok_probe then leak_probe = nil end

local unpack = rawget(table, 'unpack') or _G.unpack
local pack   = rawget(table, 'pack') or function (...)
	return { n = select('#', ...), ... }
end

local DEFAULT_SHUTDOWN_GRACE = 1.0

---@alias ExecStdin  "inherit"|"null"|"pipe"|Stream
---@alias ExecStdout "inherit"|"null"|"pipe"|Stream
---@alias ExecStderr "inherit"|"null"|"pipe"|"stdout"|Stream

--- ExecSpec: argv[1] is the programme to exec; argv[2..n] are its arguments.
---@class ExecSpec
---@field [integer] string            # argv elements (1..n)
---@field cwd string|nil
---@field env table<string,string|nil>|nil
---@field flags table|nil
---@field stdin ExecStdin|nil
---@field stdout ExecStdout|nil
---@field stderr ExecStderr|nil
---@field shutdown_grace number|nil

--- Normalised stream configuration passed through to the backend.
---@class ExecStreamConfig
---@field mode "inherit"|"null"|"pipe"|"stdout"|"stream"
---@field stream Stream|nil
---@field owned boolean              # whether the Command owns and will close the stream

---@alias CommandStatus "pending"|"running"|"exited"|"signalled"|"failed"

--- Process handle returned by the backend.
---@class ProcHandle
---@field backend ExecBackend
---@field stdin Stream|nil
---@field stdout Stream|nil
---@field stderr Stream|nil

--- Structured process command bound to a scope.
---@class Command
---@field _scope Scope
---@field _argv string[]
---@field _cwd string|nil
---@field _env table<string,string|nil>|nil
---@field _flags table
---@field _stdin ExecStreamConfig
---@field _stdout ExecStreamConfig
---@field _stderr ExecStreamConfig
---@field _shutdown_grace number
---@field _started boolean
---@field _done boolean
---@field _proc ProcHandle|nil
---@field _pid integer|nil
---@field _status CommandStatus
---@field _code integer|nil
---@field _signal integer|nil
---@field _err string|nil
---@field _finalizer_detach fun():boolean|nil
---@field _cleaned boolean
local Command = {}
Command.__index = Command

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

--- Normalise a user-facing stdio configuration into an ExecStreamConfig.
---@param value ExecStdin|ExecStdout|ExecStderr|Stream|nil
---@param is_stderr boolean
---@return ExecStreamConfig
local function norm_stream(value, is_stderr)
	if value == nil then
		return { mode = 'inherit', stream = nil, owned = true }
	end

	local t = type(value)
	if t == 'string' then
		if value == 'inherit' or value == 'null' or value == 'pipe' then
			return { mode = value, stream = nil, owned = true }
		end
		if is_stderr and value == 'stdout' then
			return { mode = 'stdout', stream = nil, owned = true }
		end
		error('invalid stdio mode: ' .. tostring(value))
	end

	if stream_mod.is_stream(value) then
		-- A user-supplied stream is not owned by the Command.
		return { mode = 'stream', stream = value, owned = false }
	end

	error('invalid stdio configuration: ' .. tostring(value))
end

---@param self Command
local function assert_not_started(self)
	if self._started then
		error('command already started')
	end
end

--- Perform an op using the current scope when it is still running, otherwise fall back to raw.
---
--- Important: use Scope:try (status-first) rather than Scope:perform to avoid raising
--- cancellation sentinels from inside op commit/wrap code paths.
---@param ev Op
---@return any ...
local function perform_with_scope_or_raw(ev)
	local s = ScopeMod.current()

	-- Scope:status() returns (st, v). We only care about the first.
	local st = s and s.status and s:status() or nil
	if s and s.try and st == 'running' then
		local r = pack(s:try(ev))
		local rst = r[1]
		if rst == 'ok' then
			return unpack(r, 2, r.n)
		end
		-- If cancelled/failed, return a conventional triple where the last
		-- value carries an error string. This avoids throwing from here.
		local msg = r[2]
		if msg == nil then
			msg = (rst == 'cancelled') and 'scope cancelled' or 'scope failed'
		end
		return nil, nil, tostring(msg)
	end

	return op.perform_raw(ev)
end

----------------------------------------------------------------------
-- Internal: process lifecycle bookkeeping
----------------------------------------------------------------------

--- Record a final exit status for this command, if not already done.
---@param code integer|nil
---@param signal integer|nil
---@param err string|nil
function Command:_record_exit(code, signal, err)
	if self._done then return end
	self._done = true

	if err then
		self._status, self._err = 'failed', err
	elseif signal ~= nil then
		self._status, self._signal = 'signalled', signal
	elseif code ~= nil then
		self._status, self._code = 'exited', code
	else
		self._status, self._err = 'failed', 'unknown process status'
	end

	self._code, self._signal = code, signal
	if leak_probe then leak_probe.exec_exit(self._probe_id, self._status, code, signal, err) end
end

--- Detach the scope finaliser once command-owned resources have been retired.
---
--- Long-lived service scopes create many short-lived exec.Command objects.  The
--- scope finaliser closure captures the command, so keeping the finaliser until
--- service shutdown retains every completed command, its backend and owned
--- streams.  Terminal commands must therefore retire themselves instead of
--- waiting for scope exit.
---@param why string
function Command:_detach_finalizer(why)
	local detach = self._finalizer_detach
	if detach then
		self._finalizer_detach = nil
		local ok, err = pcall(detach)
		if not ok and leak_probe then
			leak_probe.bump('exec.finalizer_detach_error')
		end
	end
end

--- Release command-owned resources after the backend has reached a terminal
--- state.  This is deliberately immediate and non-yielding so it is safe from
--- Op wrap callbacks and from PUC Lua pcall boundaries.  Stream:terminate()
--- closes owned fds synchronously; it does not try to drain or wait.
---@param why string
function Command:_cleanup_terminal(why)
	if self._cleaned then return end
	if not self._done then return end

	self:_detach_finalizer(why)

	for _, name in ipairs { 'stdin', 'stdout', 'stderr' } do
		local cfg = self['_' .. name]
		if cfg and cfg.stream and cfg.owned then
			local ok, err = pcall(function () cfg.stream:terminate('exec_terminal') end)
			if not ok and leak_probe then
				leak_probe.bump('exec.stream_terminate_error')
			end
			cfg.stream = nil
		end
	end

	if self._proc and self._proc.backend then
		local ok, err = self._proc.backend:close()
		if not ok and leak_probe then
			leak_probe.bump('exec.backend_close_error')
		end
		self._proc.backend = nil
	end
	self._proc = nil
	self._cleaned = true
	if leak_probe then leak_probe.exec_cleaned(self._probe_id, why or 'terminal') end
end

--- Ensure the process has been started and a ProcHandle exists.
---@return boolean ok
---@return ProcHandle|nil proc
---@return string|nil err
function Command:_ensure_started()
	if self._started then
		if self._proc then
			return true, self._proc, nil
		end
		if self._status == 'failed' then
			return false, nil, self._err
		end
		return false, nil, 'exec: command started without backend'
	end
	self._started = true

	-- High-level process spec passed to the backend.
	local spec = {
		argv   = self._argv,
		cwd    = self._cwd,
		env    = self._env,
		flags  = self._flags,
		stdin  = self._stdin,
		stdout = self._stdout,
		stderr = self._stderr,
	}

	-- Backend returns a ProcHandle:
	--   { backend = ExecBackend, stdin = Stream|nil, stdout = Stream|nil, stderr = Stream|nil }
	local proc_handle, start_err = proc_mod.start(spec)
	if not proc_handle then
		self._status = 'failed'
		self._done   = true
		self._err    = start_err
		if leak_probe then leak_probe.exec_exit(self._probe_id, 'failed', nil, nil, start_err) end
		self:_cleanup_terminal('start_failed')
		return false, nil, start_err
	end

	self._proc   = proc_handle
	self._pid    = proc_handle.backend and proc_handle.backend.pid or nil
	self._status = 'running'
	if leak_probe then leak_probe.exec_started(self._probe_id, self._pid) end

	-- If the backend created pipe streams for us, record them and mark them as owned.
	if proc_handle.stdin then
		self._stdin.stream = proc_handle.stdin
		self._stdin.owned  = true
	end
	if proc_handle.stdout then
		self._stdout.stream = proc_handle.stdout
		self._stdout.owned  = true
	end
	if proc_handle.stderr then
		self._stderr.stream = proc_handle.stderr
		self._stderr.owned  = true
	end

	return true, proc_handle, nil
end

----------------------------------------------------------------------
-- Configuration setters
----------------------------------------------------------------------

function Command:set_stdin(v)
	assert_not_started(self)
	self._stdin = norm_stream(v, false)
	return self
end

function Command:set_stdout(v)
	assert_not_started(self)
	self._stdout = norm_stream(v, false)
	return self
end

function Command:set_stderr(v)
	assert_not_started(self)
	self._stderr = norm_stream(v, true)
	return self
end

function Command:set_cwd(v)
	assert_not_started(self)
	self._cwd = v
	return self
end

function Command:set_env(v)
	assert_not_started(self)
	self._env = v
	return self
end

function Command:set_flags(v)
	assert_not_started(self)
	self._flags = v or {}
	return self
end

function Command:set_shutdown_grace(v)
	assert_not_started(self)
	self._shutdown_grace = v
	return self
end

----------------------------------------------------------------------
-- Introspection
----------------------------------------------------------------------

function Command:status()
	local st = self._status

	if st == 'exited' then
		return st, self._code, self._err
	elseif st == 'signalled' then
		return st, self._signal, self._err
	elseif st == 'failed' then
		return st, nil, self._err
	elseif st == 'pending' or st == 'running' then
		return st, nil, nil
	end

	return st, nil, self._err
end

function Command:pid()
	return self._pid
end

function Command:argv()
	local out = {}
	for i, v in ipairs(self._argv) do
		out[i] = v
	end
	return out
end

----------------------------------------------------------------------
-- Signalling
----------------------------------------------------------------------

function Command:kill(sig)
	if self._done then
		return true, nil
	end
	if not self._started then
		return false, 'command not started'
	end
	if self._status == 'failed' then
		return false, self._err or 'command failed to start'
	end

	local backend = self._proc and self._proc.backend or nil
	if not backend then
		return false, 'no backend available'
	end

	if sig ~= nil and backend.send_signal then
		return backend:send_signal(sig)
	end

	if backend.kill then
		return backend:kill()
	elseif backend.terminate then
		return backend:terminate()
	elseif backend.send_signal then
		return backend:send_signal()
	end

	return false, 'backend does not support signalling'
end

----------------------------------------------------------------------
-- Stream accessors
----------------------------------------------------------------------

function Command:stdin_stream()
	local cfg = self._stdin
	if cfg.mode == 'inherit' or cfg.mode == 'null' then
		return nil
	end
	if cfg.mode == 'stream' then
		return cfg.stream
	end
	if cfg.mode == 'pipe' then
		local ok, _, err = self:_ensure_started()
		return ok and self._stdin.stream or nil, err
	end
	return nil
end

function Command:stdout_stream()
	local cfg = self._stdout
	if cfg.mode == 'inherit' or cfg.mode == 'null' then
		return nil
	end
	if cfg.mode == 'stream' then
		return cfg.stream
	end
	if cfg.mode == 'pipe' then
		local ok, _, err = self:_ensure_started()
		return ok and self._stdout.stream or nil, err
	end
	return nil
end

function Command:stderr_stream()
	local cfg = self._stderr
	if cfg.mode == 'inherit' or cfg.mode == 'null' then
		return nil
	end
	if cfg.mode == 'stream' then
		return cfg.stream
	end
	if cfg.mode == 'pipe' then
		local ok, _, err = self:_ensure_started()
		return ok and self._stderr.stream or nil, err
	end
	if cfg.mode == 'stdout' then
		return self:stdout_stream()
	end
	return nil
end

----------------------------------------------------------------------
-- Ops: wait/run/shutdown/output
----------------------------------------------------------------------

function Command:run_op()
	return op.guard(function ()
		local ok, proc, err = self:_ensure_started()
		if not ok or not proc then
			return op.always('failed', nil, nil, err)
		end
		if self._done then
			return op.always(self._status, self._code, self._signal, self._err)
		end

		return proc.backend:wait_op():wrap(function (...)
			self:_record_exit(...)
			local status, code, signal, err = self._status, self._code, self._signal, self._err
			self:_cleanup_terminal('terminal')
			return status, code, signal, err
		end)
	end)
end

function Command:shutdown_op(grace)
	return op.guard(function ()
		local ok, proc, err = self:_ensure_started()
		if not (ok and proc) then
			return op.always('failed', nil, nil, err)
		end
		if self._done then
			return op.always(self._status, self._code, self._signal, self._err)
		end

		local g = grace or self._shutdown_grace or DEFAULT_SHUTDOWN_GRACE

		-- Polite termination: delegate behaviour to backend.
		if proc.backend and proc.backend.terminate then
			proc.backend:terminate()
		elseif proc.backend and proc.backend.send_signal then
			proc.backend:send_signal()
		end

		local choice_ev = op.boolean_choice(
			self:run_op():wrap(function (status, code, signal, e)
				return true, status, code, signal, e
			end),
			sleep.sleep_op(g):wrap(function ()
				return false
			end)
		)

		return choice_ev:wrap(function (is_exit, status, code, signal, e)
			if is_exit then
				return status, code, signal, e
			end

			-- Grace period elapsed. Try a forceful kill.
			local kill_err
			if proc.backend then
				if proc.backend.kill then
					local ok2, err2 = proc.backend:kill()
					if not ok2 and err2 then
						kill_err = err2
					end
				elseif proc.backend.send_signal then
					local ok2, err2 = proc.backend:send_signal()
					if not ok2 and err2 then
						kill_err = err2
					end
				end
			end

			-- Wait for completion, using the current scope when running (status-first),
			-- otherwise falling back to raw waiting.
			local code2, signal2, err2 = perform_with_scope_or_raw(proc.backend:wait_op())
			self:_record_exit(code2, signal2, err2)
			local err_final = kill_err or err2
			return self._status, self._code, self._signal, err_final
		end)
	end)
end

function Command:output_op()
	return op.guard(function ()
		-- If stdout is currently inherited, default to piping for this helper.
		if not self._started and (self._stdout.mode == 'inherit' or self._stdout.mode == nil) then
			self._stdout = norm_stream('pipe', false)
		end

		local ok, _, err = self:_ensure_started()
		if not ok then
			return op.always('', 'failed', nil, nil, err)
		end

		local stream, serr = self:stdout_stream()
		if not stream then
			return op.always('', 'failed', nil, nil, serr or 'no stdout stream available')
		end

		return stream:read_all_op():wrap(function (out, io_err)
			local status, code, signal, perr = perform_with_scope_or_raw(self:run_op())
			local err_final = io_err or perr
			return out or '', status, code, signal, err_final
		end)
	end)
end

function Command:combined_output_op()
	if self._stderr.mode == 'pipe' or self._stderr.mode == 'stream' then
		error('combined_output_op: stderr must not already be a pipe or stream')
	end
	if not self._started and (self._stderr.mode == 'inherit' or self._stderr.mode == nil) then
		self._stderr = norm_stream('stdout', true)
	end
	return self:output_op()
end

----------------------------------------------------------------------
-- Finaliser-only shutdown (non-interruptible)
----------------------------------------------------------------------

--- Best-effort shutdown used during scope finalisation.
--- This path must not be interruptible by scope cancellation.
---@param grace number|nil
function Command:_shutdown_uninterruptible(grace)
	if not (self._started and not self._done) then
		return
	end

	local ok, proc = self:_ensure_started()
	if not (ok and proc and proc.backend) then
		return
	end

	local g = grace or self._shutdown_grace or DEFAULT_SHUTDOWN_GRACE

	-- Polite termination.
	if proc.backend.terminate then
		proc.backend:terminate()
	elseif proc.backend.send_signal then
		proc.backend:send_signal()
	end

	-- Race exit against grace timer without involving scope cancellation.
	local is_exit, _, _, _, _ = op.perform_raw(
		op.boolean_choice(
			self:run_op():wrap(function (st, c, sig, perr)
				return true, st, c, sig, perr
			end),
			sleep.sleep_op(g):wrap(function ()
				return false
			end)
		)
	)

	if not is_exit then
		-- Escalate.
		if proc.backend.kill then
			proc.backend:kill()
		elseif proc.backend.send_signal then
			proc.backend:send_signal()
		end

		-- Ensure the process is waited for (uninterruptible).
		local code2, signal2, err2 = op.perform_raw(proc.backend:wait_op())
		self:_record_exit(code2, signal2, err2)
		self:_cleanup_terminal('scope_exit')

		-- Preserve any earlier status data if present.
		-- (status/code/signal/e are unused here by design.)
		return
	end

	-- If it exited during the grace period, run_op has already recorded status.
	-- Nothing more to do here.
	return
end

----------------------------------------------------------------------
-- Scope cleanup
----------------------------------------------------------------------

function Command:_on_scope_exit()
	if self._cleaned then return end
	if leak_probe then leak_probe.exec_scope_exit(self._probe_id) end
	if self._started and not self._done then
		-- Non-interruptible best-effort shutdown.
		self:_shutdown_uninterruptible(self._shutdown_grace)
	end

	for _, name in ipairs { 'stdin', 'stdout', 'stderr' } do
		local cfg = self['_' .. name]
		if cfg.stream and cfg.owned then
			local ok, err = op.perform_raw(cfg.stream:close_op())
			if not ok then
				error(err or ('failed to close ' .. name .. ' stream'))
			end
			cfg.stream = nil
		end
	end

	if self._proc and self._proc.backend then
		local ok, err = self._proc.backend:close()
		if not ok then
			error(err or 'failed to close process backend')
		end
		self._proc.backend = nil
	end
	self._proc = nil
	self._cleaned = true
	if leak_probe then leak_probe.exec_cleaned(self._probe_id, 'scope_exit') end
end

----------------------------------------------------------------------
-- Command construction
----------------------------------------------------------------------

---@param spec ExecSpec
---@return Command
local function command_from_spec(spec)
	assert(Runtime.current_fiber(), 'exec.command must be called from inside a fiber')
	local scope = ScopeMod.current()

	local argv = {}
	local i    = 1
	while spec[i] ~= nil do
		argv[i] = assert(spec[i], 'argv must not contain nil')
		i = i + 1
	end
	assert(argv[1], 'exec.command: argv[1] must be non-nil')

	local probe_id = leak_probe and leak_probe.exec_next_id() or nil
	local cmd = setmetatable({
		_probe_id       = probe_id,
		_scope          = scope,
		_argv           = argv,
		_cwd            = spec.cwd,
		_env            = spec.env,
		_flags          = spec.flags or {},
		_stdin          = norm_stream(spec.stdin, false),
		_stdout         = norm_stream(spec.stdout, false),
		_stderr         = norm_stream(spec.stderr, true),
		_shutdown_grace = spec.shutdown_grace or DEFAULT_SHUTDOWN_GRACE,
		_started        = false,
		_done           = false,
		_proc           = nil,
		_pid            = nil,
		_status         = 'pending',
		_code           = nil,
		_signal         = nil,
		_err            = nil,
		_finalizer_detach = nil,
		_cleaned        = false,
	}, Command)

	if leak_probe then leak_probe.exec_created(probe_id, scope and scope._id or nil, argv) end

	cmd._finalizer_detach = scope:finally(function ()
		cmd:_on_scope_exit()
	end)

	return cmd
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

local exec = {}

---@class ExecBackendModule
---@field start fun(spec: ExecSpec): ProcHandle|nil, string|nil

---@overload fun(spec: ExecSpec): Command
---@param ... any
---@return Command
function exec.command(...)
	local n = select('#', ...)
	if n == 1 and type((...)) == 'table' then
		return command_from_spec((...))
	end

	assert(n > 0, 'exec.command: at least one argv element required')
	local spec = {}
	for i = 1, n do
		spec[i] = assert(select(i, ...), 'argv must not contain nil')
	end
	return command_from_spec(spec)
end

exec.Command = Command

return exec
