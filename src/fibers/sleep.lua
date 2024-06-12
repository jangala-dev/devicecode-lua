-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

--- fibers.sleep module.
-- Provides functions to suspend execution of fibers for a certain duration (sleep) or until a specific time.
-- @module fibers.sleep

local op = require 'fibers.op'
local fiber = require 'fibers.fiber'

--- Timeout class.
-- Represents a timeout for a fiber.
-- @type Timeout
-- local Timeout = {}
-- Timeout.__index = Timeout

--- Create a new operation that puts the current fiber to sleep until the time t.
-- @tparam number t The time to sleep until.
-- @treturn operation The created operation.
local function sleep_until_op(t)
    local function try()
        return t <= fiber.now()
    end
    local function block(suspension, wrap_fn)
        suspension.sched:schedule_at_time(t, suspension:complete_task(wrap_fn))
    end
    return op.new_base_op(nil, try, block)
end

--- Put the current fiber to sleep until time t.
-- @tparam number t The time to sleep until.
local function sleep_until(t)
    return sleep_until_op(t):perform()
end

--- Create a new operation that puts the current fiber to sleep for a duration dt.
-- @tparam number dt The duration to sleep.
-- @treturn operation The created operation.
local function sleep_op(dt)
    local function try() return dt <= 0 end
    local function block(suspension, wrap_fn)
        suspension.sched:schedule_after_sleep(dt, suspension:complete_task(wrap_fn))
    end
    return op.new_base_op(nil, try, block)
end

--- Put the current fiber to sleep for a duration dt.
-- @tparam number dt The duration to sleep.
local function sleep(dt)
    return sleep_op(dt):perform()
end

return {
    sleep = sleep,
    sleep_op = sleep_op,
    sleep_until = sleep_until,
    sleep_until_op = sleep_until_op
}
