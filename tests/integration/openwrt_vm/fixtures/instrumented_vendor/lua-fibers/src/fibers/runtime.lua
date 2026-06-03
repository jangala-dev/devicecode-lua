-- fibers/runtime.lua
---
-- Runtime module for fibers.
-- Provides a global scheduler, fiber creation, suspension and error reporting.
---@module 'fibers.runtime'

local sched = require 'fibers.sched'

--- Identity helper used as the wrap function when resuming fibers.
---@generic T
---@param ... T
---@return T ...
local function id(...)
	return ...
end

--- Record of an uncaught fiber error.
---@class FiberErrorRecord
---@field fiber Fiber
---@field err any

--- Record of a fiber waiting for an error notification.
---@class ErrorWaiterRecord
---@field fiber Fiber

---@type FiberErrorRecord[]
local error_queue = {}

---@type ErrorWaiterRecord[]
local error_waiters = {}

--- Task used to wake a fiber waiting for an error.
---@class WaiterTask : Task
---@field waiter Fiber     # waiting fiber
---@field err_fiber Fiber  # fiber that failed
---@field err any          # error value
local WaiterTask = {}
WaiterTask.__index = WaiterTask

--- Resume the waiting fiber with (wrap, err_fiber, err).
function WaiterTask:run()
	self.waiter:resume(id, self.err_fiber, self.err)
end

--- Cooperative fiber object managed by the runtime.
---@class Fiber : Task
---@field coroutine thread
---@field alive boolean
---@field sockets table<any, any>
---@field traceback string|nil
local Fiber = {}
Fiber.__index = Fiber

---@type Fiber|nil
local _current_fiber

---@type Scheduler
local current_scheduler = sched.new()

--- Spawn a new fiber scheduled on the global scheduler.
--- The function is called as fn(wrap, ...), where wrap is typically the identity.
---@param fn fun(wrap: fun(...: any): any, ...: any)
local function spawn(fn)
	local tb = debug.traceback('', 2):match('\n[^\n]*\n(.*)') or ''
	if _current_fiber and _current_fiber.traceback then
		tb = tb .. '\n' .. _current_fiber.traceback
	end

	current_scheduler:schedule(
		setmetatable({
			coroutine = coroutine.create(fn),
			alive     = true,
			sockets   = {},
			traceback = tb,
		}, Fiber)
	)
end

--- Resume execution of this fiber.
--- If the fiber is dead, an error is raised.
---@param wrap fun(...: any): any
---@param ... any
function Fiber:resume(wrap, ...)
	assert(self.alive, 'dead fiber')
	local saved_current_fiber = _current_fiber
	_current_fiber = self
	local ok, err = coroutine.resume(self.coroutine, wrap, ...)
	_current_fiber = saved_current_fiber

	if coroutine.status(self.coroutine) == 'dead' then
		self.alive = false
	end

	if not ok then
		-- Report uncaught error to any waiting fiber, or queue it.
		if #error_waiters > 0 then
			local waiter = table.remove(error_waiters, 1)
			current_scheduler:schedule(setmetatable({
				waiter    = waiter.fiber,
				err_fiber = self,
				err       = err,
			}, WaiterTask))
		else
			error_queue[#error_queue + 1] = {
				fiber = self,
				err   = err,
			}
		end
	end
end

--- Alias for :resume, so a Fiber can be scheduled as a Task.
Fiber.run = Fiber.resume

--- Suspend this fiber until block_fn arranges to reschedule it.
--- block_fn receives (scheduler, fiber, ...).
---@param block_fn fun(scheduler: Scheduler, fiber: Fiber, ...: any)
---@param ... any
---@return any ...
function Fiber:suspend(block_fn, ...)
	assert(_current_fiber == self)
	block_fn(current_scheduler, assert(_current_fiber), ...)
	return coroutine.yield()
end

--- Return the captured creation traceback for this fiber, if any.
---@return string
function Fiber:get_traceback()
	return self.traceback or 'No traceback available'
end

--- Return the current Fiber object, or nil if not inside a fiber.
---@return Fiber|nil
local function current_fiber()
	return _current_fiber
end

--- Current scheduler time in monotonic seconds.
---@return number
local function now()
	return current_scheduler:now()
end

--- Suspend the current fiber using block_fn.
--- block_fn must arrange for the fiber to be rescheduled later.
---@param block_fn fun(scheduler: Scheduler, fiber: Fiber, ...: any)
---@param ... any
---@return any ...
local function suspend(block_fn, ...)
	assert(_current_fiber, 'can only suspend from inside a fiber')
	return _current_fiber:suspend(block_fn, ...)
end

--- Yield the current fiber and re-queue it as runnable.
---@return any ...
local function yield()
	assert(current_fiber(), 'can only yield from inside a fiber')
	return suspend(function (scheduler, fiber)
		scheduler:schedule(fiber)
	end)
end

--- Request that the global scheduler stops its main loop.
local function stop()
	current_scheduler:stop()
end

--- Wait for the next uncaught fiber error.
--- Returns the failing fiber and its error value.
---@return Fiber err_fiber
---@return any err
local function wait_fiber_error()
	if #error_queue > 0 then
		local rec = table.remove(error_queue, 1)
		return rec.fiber, rec.err
	end

	assert(_current_fiber, 'wait_fiber_error must be called from within a fiber')

	local function block_fn(_, fib)
		error_waiters[#error_waiters + 1] = { fiber = fib }
	end

	local _, err_fiber, err = _current_fiber:suspend(block_fn)
	return err_fiber, err
end

--- Run the main event loop using the global scheduler.
local function main()
	return current_scheduler:main()
end

return {
	current_scheduler = current_scheduler,
	current_fiber     = current_fiber,
	now               = now,
	suspend           = suspend,
	yield             = yield,
	wait_fiber_error  = wait_fiber_error,

	-- fiber management
	spawn_raw = spawn,
	stop      = stop,
	main      = main,
}
