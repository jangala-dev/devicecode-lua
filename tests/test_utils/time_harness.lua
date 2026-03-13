local fibers  = require 'fibers'
local runtime = require 'fibers.runtime'

local perform = fibers.perform
local pack    = rawget(table, 'pack') or function(...)
    return { n = select('#', ...), ... }
end
local unpack  = rawget(table, 'unpack') or unpack

---@class VirtualClock
---@field advance fun(self: VirtualClock, dt: number): number

---@class TimeHarnessTickOpts
---@field max_ticks? integer

---@class TimeHarnessWaitTicksOpts
---@field max_ticks? integer
---@field on_miss? fun(tick: integer)

---@class TimeHarnessWaitWithinOpts
---@field step? number
---@field max_ticks? integer

local M = {}
local NOT_READY = {}

---@param op_or_factory any|fun(): any
---@return any
local function resolve_op(op_or_factory)
    if type(op_or_factory) == 'function' then
        return op_or_factory()
    end
    return op_or_factory
end

---@param op_or_factory any|fun(): any
---@return boolean
---@return ...
function M.try_op_now(op_or_factory)
    local op = resolve_op(op_or_factory)
    local out = pack(perform(op:or_else(function() return NOT_READY end)))
    if out.n == 1 and out[1] == NOT_READY then
        return false
    end
    return true, unpack(out, 1, out.n)
end

---@param max_ticks? integer
function M.flush_ticks(max_ticks)
    max_ticks = max_ticks or 1
    for _ = 1, max_ticks do
        runtime.yield()
    end
end

---@param op_or_factory any|fun(): any
---@param opts? TimeHarnessWaitTicksOpts
---@return boolean
---@return ...
function M.wait_op_ticks(op_or_factory, opts)
    opts = opts or {}

    local max_ticks = opts.max_ticks or 1
    local on_miss = opts.on_miss

    for tick = 0, max_ticks do
        local out = pack(M.try_op_now(op_or_factory))
        if out[1] then
            return unpack(out, 1, out.n)
        end

        if tick == max_ticks then break end

        if on_miss then
            on_miss(tick + 1)
        else
            runtime.yield()
        end
    end

    return false
end

---@param clock VirtualClock
---@param timeout_s number
---@param op_or_factory any|fun(): any
---@param opts? TimeHarnessWaitWithinOpts
---@return boolean
---@return ...
function M.wait_op_within(clock, timeout_s, op_or_factory, opts)
    opts = opts or {}

    local step = opts.step or timeout_s
    local max_ticks = opts.max_ticks or 1
    local elapsed = 0

    while true do
        local out = pack(M.try_op_now(op_or_factory))
        if out[1] then
            return unpack(out, 1, out.n)
        end
        if elapsed >= timeout_s then
            return false
        end

        local advance = math.min(step, timeout_s - elapsed)
        clock:advance(advance)
        M.flush_ticks(max_ticks)
        elapsed = elapsed + advance
    end
end

return M
