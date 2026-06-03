-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

--- Sleep operations for fibers.
--- Provides ops and helpers for suspending fibers for a duration or until a deadline.
---@module 'fibers.sleep'

local op      = require 'fibers.op'
local runtime = require 'fibers.runtime'

local perform = require 'fibers.performer'.perform

--- Primitive op that becomes ready when the absolute time t is reached.
---@param t number  # absolute time on the runtime clock
---@return Op
local function deadline_op(t)
	local function try()
		return runtime.now() >= t
	end

	--- Schedule completion of the suspension at time t.
	---@param suspension Suspension
	---@param wrap_fn WrapFn
	local function block(suspension, wrap_fn)
		local cancel_timer = suspension:at_time(t, suspension:complete_task(wrap_fn))
		suspension:add_cleanup(cancel_timer)
	end

	return op.new_primitive(nil, try, block)
end

--- Op that sleeps until absolute time t.
---@param t number  # absolute time on the runtime clock
---@return Op
local function sleep_until_op(t)
	return deadline_op(t)
end

--- Sleep until absolute time t.
---@param t number  # absolute time on the runtime clock
local function sleep_until(t)
	return perform(sleep_until_op(t))
end

--- Op that sleeps for a duration dt.
---@param dt number  # delay in seconds
---@return Op
local function sleep_op(dt)
	return op.guard(function ()
		return deadline_op(runtime.now() + dt)
	end)
end

--- Sleep for a duration dt.
---@param dt number  # delay in seconds
local function sleep(dt)
	return perform(sleep_op(dt))
end

return {
	sleep          = sleep,
	sleep_op       = sleep_op,
	sleep_until    = sleep_until,
	sleep_until_op = sleep_until_op,
}
