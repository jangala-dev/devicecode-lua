-- fibers/io/exec_backend/core.lua
--
-- Core glue for exec backends.
--
-- This owns the public ExecBackend shape and semantics.
-- Backend modules provide only low-level primitives; build_backend
-- wires those into a concrete { start, ExecBackend, is_supported } module.
--
---@module 'fibers.io.exec_backend.core'

local waitmod = require 'fibers.wait'

---@class ExecBackend
---@field pid integer|nil
---@field exited boolean
---@field status integer|nil
---@field code integer|nil
---@field signal integer|nil
---@field err string|nil
---@field _state any
---@field _ops table
local ExecBackend = {}
ExecBackend.__index = ExecBackend

--- Wait for the process to complete, returning (code, signal, err).
---@return Op
function ExecBackend:wait_op()
	local ops   = self._ops
	local state = self._state

	local function step()
		if self.exited then
			return true, self.code, self.signal, self.err
		end

		local done, code, signal, err = ops.poll(state)
		if not done then
			return false
		end

		self.exited = true
		self.code   = code
		self.signal = signal
		self.err    = err
		return true, self.code, self.signal, self.err
	end

	---@param task Task
	---@param suspension Suspension
	---@param leaf_wrap WrapFn
	local function register(task, suspension, leaf_wrap)
		return ops.register_wait(state, task, suspension, leaf_wrap)
	end

	local function wrap(code, signal, err)
		return code, signal, err
	end

	return waitmod.waitable(register, step, wrap)
end

function ExecBackend:send_signal(sig)
	local ops = self._ops
	if ops.send_signal then
		return ops.send_signal(self._state, sig)
	end
	return false, 'backend does not support send_signal'
end

function ExecBackend:terminate()
	local ops = self._ops
	if ops.terminate then
		return ops.terminate(self._state)
	elseif ops.send_signal then
		return ops.send_signal(self._state, nil)
	end
	return false, 'backend does not support terminate'
end

function ExecBackend:kill()
	local ops = self._ops
	if ops.kill then
		return ops.kill(self._state)
	elseif ops.send_signal then
		return ops.send_signal(self._state, nil)
	end
	return false, 'backend does not support kill'
end

function ExecBackend:close()
	local ops = self._ops
	if ops.close then
		return ops.close(self._state)
	end
	return true, nil
end

----------------------------------------------------------------------
-- Backend builder
----------------------------------------------------------------------

--- Build a concrete exec backend module from low-level ops.
---
--- Required ops:
---   spawn(spec) -> state, streams, err|nil
---       state   : backend-private state (must at least contain state.pid)
---       streams : { stdin = Stream|nil, stdout = Stream|nil, stderr = Stream|nil }
---
---   poll(state) -> done:boolean, code|nil, signal|nil, err|nil
---       Non-blocking; done=false means “still running”.
---
---   register_wait(state, task, suspension, leaf_wrap) -> WaitToken
---       Register a Task to be run when progress may have been made.
---
--- Optional ops:
---   send_signal(state, sig)   -> ok:boolean, err|nil
---   terminate(state)          -> ok:boolean, err|nil
---   kill(state)               -> ok:boolean, err|nil
---   close(state)              -> ok:boolean, err|nil
---   is_supported()            -> boolean
---
---@param ops table
---@return table backend_module  -- { start = fn, ExecBackend = ExecBackend, is_supported = fn }
local function build_backend(ops)
	assert(type(ops) == 'table', 'exec_backend ops must be a table')
	assert(type(ops.spawn) == 'function', 'ops.spawn must be a function')
	assert(type(ops.poll) == 'function', 'ops.poll must be a function')
	assert(type(ops.register_wait) == 'function', 'ops.register_wait must be a function')

	local function start(spec)
		local state, streams, err = ops.spawn(spec)
		if not state then
			return nil, err
		end

		local backend = setmetatable({
			_ops   = ops,
			_state = state,

			pid    = state.pid, -- for introspection
			exited = false,
			status = nil,
			code   = nil,
			signal = nil,
			err    = nil,
		}, ExecBackend)

		local handle = {
			backend = backend,
			stdin   = streams and streams.stdin or nil,
			stdout  = streams and streams.stdout or nil,
			stderr  = streams and streams.stderr or nil,
		}

		return handle, nil
	end

	local function is_supported()
		if type(ops.is_supported) == 'function' then
			return not not ops.is_supported()
		end
		return true
	end

	return {
		ExecBackend  = ExecBackend,
		start        = start,
		is_supported = is_supported,
	}
end

return {
	ExecBackend   = ExecBackend,
	build_backend = build_backend,
}
