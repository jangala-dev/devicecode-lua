--- A Lua context library for managing hierarchies of fibers with cancellation, deadlines, and values.
-- This library provides a way to create and manage context objects, similar to the context package in Go.
-- Each context can carry a set of key-value pairs (values), a cancellation signal, and a deadline.
-- Children contexts can be derived from a parent context, inheriting and extending its values.
-- @module context

local fiber = require 'fibers.fiber'
local waitgroup = require 'fibers.waitgroup'
local op = require 'fibers.op'
local sleep = require 'fibers.sleep'

--- Context class.
-- Represents a context in the fiber system.
-- @type Context
local Context = {}
Context.__index = Context

--- Creates a new background context.
-- This is the root context for all others; it is never canceled, has no deadline, and carries no values.
-- @return Context A new background context.
local function background()
    return setmetatable({
        values = {},
        children = {}
    }, Context)
end

--- Creates a new context with cancellation, derived from a parent context.
-- @param Context parent The parent context from which to derive the new context.
-- @return Context The new context.
-- @return function Cancellation function.
local function with_cancel(parent)
    local wg = waitgroup.new()
    wg:add(1)
    local ctx = setmetatable({
        wg = wg,
        children = {},
        -- Creates a new table that inherits from 'parent.values', enabling access to parent's values + overriding.
        values = setmetatable({}, {__index = parent.values})
    }, Context)

    function ctx:cancel(cause)
        if self.cause then return end
        if not cause then cause = "canceled" end
        self.cause = cause
        wg:done()
        for _, child in ipairs(self.children) do
            if child.cancel then child:cancel(cause) end
        end
    end

    table.insert(parent.children, ctx)

    return ctx, function(cause) ctx:cancel(cause) end
end

--- Creates a new context with a deadline.
-- The context will be canceled automatically when the deadline is exceeded.
-- @param Context parent The parent context.
-- @param number deadline The time at which to cancel the context.
-- @return Context The new context.
-- @return function Cancellation function.
local function with_deadline(parent, deadline)
    local ctx, cancel = with_cancel(parent)
    fiber.spawn(function()
        sleep.sleep_until(deadline)
        ctx:cancel("deadline_exceeded")
    end)
    return ctx, cancel
end

--- Creates a new context with a timeout.
-- The context will be canceled automatically after the timeout duration.
-- @param parent The parent context.
-- @param timeout The duration in seconds after which to cancel the context.
-- @return Context The new context.
-- @return function Cancellation function.
local function with_timeout(parent, timeout)
    return with_deadline(parent, fiber.now() + timeout)
end

--- Creates a new context with an additional key-value pair.
-- @param Context parent The parent context.
-- @param string key The key for the value to add.
-- @param any value The value to add.
-- @return Context The new context.
local function with_value(parent, key, value)
    local ctx = setmetatable({
        children = {},
        values = setmetatable({[key] = value}, {__index = parent.values})
    }, Context)
    return ctx
end

--- Returns an operation that can be used in `op.choice` to wait for the context to be done.
-- @return function An operation that can be used with `op.choice`.
function Context:done_op()
    if not self.wg then
        return op.new_base_op(nil, function() return true end, nil)
    end
    return self.wg:wait_op()
end

--- Accesses a value stored in the context.
-- @param string key The key for the value to retrieve.
-- @return any The value associated with the given key, or nil if not found.
function Context:value(key)
    return self.values[key]
end

--- Returns the cause of the cancellation, if any.
-- @return string|nil A string describing the cause of cancellation, or nil if not canceled.
function Context:err()
    return self.cause
end

return {
    background = background,
    with_cancel = with_cancel,
    with_deadline = with_deadline,
    with_timeout = with_timeout,
    with_value = with_value
}
