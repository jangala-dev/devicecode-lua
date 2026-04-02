-- services/hal/managers/power.lua
--
-- Power HAL Manager.
-- Creates a single PowerDriver, registers it with HAL, and holds its
-- scope until the manager is stopped.

local power_driver = require "services.hal.drivers.power"
local hal_types    = require "services.hal.types.core"

---@type any
local power_driver_any = power_driver

local fibers = require "fibers"
local op     = require "fibers.op"
local sleep  = require "fibers.sleep"

local STOP_TIMEOUT = 5.0

local function dlog(logger, level, payload)
    if logger and logger[level] then
        logger[level](logger, payload)
    end
end

---@class PowerManager
---@field scope Scope?
---@field started boolean
---@field logger Logger?
local PowerManager = {
    started = false,
    scope   = nil,
    logger  = nil,
}

---- manager fiber ----

---@param scope Scope
---@param dev_ev_ch Channel
---@param cap_emit_ch Channel
local function manager(scope, dev_ev_ch, cap_emit_ch)
    dlog(PowerManager.logger, 'debug', { what = 'started' })

    scope:finally(function()
        dlog(PowerManager.logger, 'debug', { what = 'closed' })
    end)

    local driver_logger = nil
    if PowerManager.logger and PowerManager.logger.child then
        driver_logger = PowerManager.logger:child({ component = 'driver', driver = 'power', id = '1' })
    end

    local driver, drv_err = power_driver_any.new(driver_logger)
    if not driver then
        error("Power Manager: failed to create power driver: " .. tostring(drv_err))
    end

    local init_err = driver:init()
    if init_err ~= "" then
        error("Power Manager: failed to init driver: " .. tostring(init_err))
    end

    local capabilities, cap_err = driver:capabilities(cap_emit_ch)
    if cap_err ~= "" then
        error("Power Manager: failed to bind capabilities: " .. tostring(cap_err))
    end

    local ok, start_err = driver:start()
    if not ok then
        error("Power Manager: failed to start driver: " .. tostring(start_err))
    end

    local device_event, ev_err = hal_types.new.DeviceEvent(
        "added", "power", "1", {}, capabilities)
    if not device_event then
        error("Power Manager: failed to create DeviceEvent: " .. tostring(ev_err))
    end
    dev_ev_ch:put(device_event)

    dlog(PowerManager.logger, 'info', { what = 'device_registered' })
end

---- public interface ----

---@param logger Logger?
---@param dev_ev_ch Channel
---@param cap_emit_ch Channel
---@return string error
function PowerManager.start(logger, dev_ev_ch, cap_emit_ch)
    if PowerManager.started then
        return "Already started"
    end

    local scope, err = fibers.current_scope():child()
    if not scope then
        return "Failed to create child scope: " .. tostring(err)
    end
    PowerManager.scope = scope
    PowerManager.logger = logger

    scope:finally(function()
        local st, primary = scope:status()
        if st == 'failed' then
            dlog(PowerManager.logger, 'error', { what = 'scope_failed', err = tostring(primary), status = st })
        end
        dlog(PowerManager.logger, 'debug', { what = 'stopped' })
    end)

    scope:spawn(manager, dev_ev_ch, cap_emit_ch)

    PowerManager.started = true
    dlog(PowerManager.logger, 'debug', { what = 'start_called' })
    return ""
end

---@param timeout number?
---@return boolean ok
---@return string error
function PowerManager.stop(timeout)
    if not PowerManager.started then
        return false, "Not started"
    end
    timeout = timeout or STOP_TIMEOUT
    PowerManager.scope:cancel('power manager stopped')

    local source = fibers.perform(op.named_choice {
        join    = PowerManager.scope:join_op(),
        timeout = sleep.sleep_op(timeout),
    })

    if source == 'timeout' then
        return false, "power manager stop timeout"
    end
    PowerManager.started = false
    return true, ""
end

---@param namespaces table
---@return boolean ok
---@return string error
function PowerManager.apply_config(namespaces) -- luacheck: ignore
    return true, ""
end

return PowerManager
