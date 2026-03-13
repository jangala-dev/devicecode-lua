local runtime = require 'fibers.runtime'
local time    = require 'fibers.utils.time'

---@class VirtualTimeInstallOpts
---@field monotonic? number
---@field realtime? number
---@field follow_realtime? boolean

---@class VirtualClock
---@field monotonic fun(self: VirtualClock): number
---@field realtime fun(self: VirtualClock): number
---@field set_monotonic fun(self: VirtualClock, value: number): number
---@field set_realtime fun(self: VirtualClock, value: number): number
---@field advance fun(self: VirtualClock, dt: number): number
---@field restore fun(self: VirtualClock)

local M = {}

---@type VirtualClock|nil
local active_clock = nil

---@param value number|nil
---@param fallback number
---@return number
local function now_or(value, fallback)
    if value ~= nil then return value end
    return fallback
end

---@param opts? VirtualTimeInstallOpts
---@return VirtualClock
function M.install(opts)
    if active_clock then
        error('virtual_time.install: a clock is already installed')
    end

    opts = opts or {}

    local scheduler = runtime.current_scheduler
    local original = {
        monotonic      = time.monotonic,
        realtime       = time.realtime,
        block          = time._block,
        scheduler_time = scheduler.get_time,
    }

    local state = {
        scheduler       = scheduler,
        original        = original,
        monotonic       = now_or(opts.monotonic, scheduler:now()),
        realtime        = now_or(opts.realtime, time.realtime()),
        follow_realtime = opts.follow_realtime ~= false,
        restored        = false,
    }

    local function monotonic_now()
        return state.monotonic
    end

    local function realtime_now()
        return state.realtime
    end

    time.monotonic = monotonic_now
    time.realtime = realtime_now
    time._block = function()
        return true
    end

    scheduler.get_time = monotonic_now
    scheduler.wheel.now = state.monotonic

    local clock = {}

    function clock:monotonic()
        return state.monotonic
    end

    function clock:realtime()
        return state.realtime
    end

    function clock:set_monotonic(value)
        assert(type(value) == 'number', 'virtual_time.set_monotonic: value must be a number')
        assert(value >= state.monotonic, 'virtual_time.set_monotonic: cannot move time backwards')
        state.monotonic = value
        return state.monotonic
    end

    function clock:set_realtime(value)
        assert(type(value) == 'number', 'virtual_time.set_realtime: value must be a number')
        state.realtime = value
        return state.realtime
    end

    function clock:advance(dt)
        assert(type(dt) == 'number', 'virtual_time.advance: dt must be a number')
        assert(dt >= 0, 'virtual_time.advance: dt must be non-negative')
        state.monotonic = state.monotonic + dt
        if state.follow_realtime then
            state.realtime = state.realtime + dt
        end
        return state.monotonic
    end

    function clock:restore()
        if state.restored then return end
        if active_clock ~= clock then
            error('virtual_time.restore: attempted to restore a non-active clock')
        end

        scheduler.get_time = original.scheduler_time
        scheduler.wheel.now = scheduler.get_time()
        time.monotonic = original.monotonic
        time.realtime = original.realtime
        time._block = original.block

        state.restored = true
        active_clock = nil
    end

    ---@cast clock VirtualClock
    active_clock = clock
    return clock
end

return M
