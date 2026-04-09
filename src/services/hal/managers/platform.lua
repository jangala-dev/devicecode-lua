-- services/hal/managers/platform.lua
--
-- Platform HAL Manager.
-- Creates a single PlatformDriver, registers it with HAL, and holds its
-- scope until the manager is stopped.

local platform_driver = require "services.hal.drivers.platform"
local hal_types       = require "services.hal.types.core"

---@type any
local platform_driver_any = platform_driver

local fibers = require "fibers"
local op     = require "fibers.op"
local sleep  = require "fibers.sleep"

local STOP_TIMEOUT = 5.0

local function dlog(logger, level, payload)
    if logger and logger[level] then
        logger[level](logger, payload)
    end
end

---@class PlatformManager
---@field scope Scope?
---@field started boolean
---@field logger Logger?
local PlatformManager = {
    started = false,
    scope   = nil,
    logger  = nil,
}

---- manager fiber ----

---@param scope Scope
---@param dev_ev_ch Channel
---@param cap_emit_ch Channel
local function manager(scope, dev_ev_ch, cap_emit_ch)
    dlog(PlatformManager.logger, 'debug', { what = 'started' })

    scope:finally(function()
        dlog(PlatformManager.logger, 'debug', { what = 'closed' })
    end)

    local driver_logger = nil
    if PlatformManager.logger and PlatformManager.logger.child then
        driver_logger = PlatformManager.logger:child({ component = 'driver', driver = 'platform', id = '1' })
    end

    local driver, drv_err = platform_driver_any.new(driver_logger)
    if not driver then
        error("Platform Manager: failed to create platform driver: " .. tostring(drv_err))
    end

    local init_err = driver:init()
    if init_err ~= "" then
        error("Platform Manager: failed to init driver: " .. tostring(init_err))
    end

    local capabilities, cap_err = driver:capabilities(cap_emit_ch)
    if cap_err ~= "" then
        error("Platform Manager: failed to bind capabilities: " .. tostring(cap_err))
    end

    local ok, start_err = driver:start()
    if not ok then
        error("Platform Manager: failed to start driver: " .. tostring(start_err))
    end

    local device_event, ev_err = hal_types.new.DeviceEvent(
        "added", "platform", "1", {}, capabilities)
    if not device_event then
        error("Platform Manager: failed to create DeviceEvent: " .. tostring(ev_err))
    end
    dev_ev_ch:put(device_event)

    dlog(PlatformManager.logger, 'info', { what = 'device_registered' })
end

---- public interface ----

---@param logger Logger?
---@param dev_ev_ch Channel
---@param cap_emit_ch Channel
---@return string error
function PlatformManager.start(logger, dev_ev_ch, cap_emit_ch)
    if PlatformManager.started then
        return "Already started"
    end

    local scope, err = fibers.current_scope():child()
    if not scope then
        return "Failed to create child scope: " .. tostring(err)
    end
    PlatformManager.scope = scope
    PlatformManager.logger = logger

    scope:finally(function()
        local st, primary = scope:status()
        if st == 'failed' then
            dlog(PlatformManager.logger, 'error', { what = 'scope_failed', err = tostring(primary), status = st })
        end
        dlog(PlatformManager.logger, 'debug', { what = 'stopped' })
    end)

    scope:spawn(manager, dev_ev_ch, cap_emit_ch)

    PlatformManager.started = true
    dlog(PlatformManager.logger, 'debug', { what = 'start_called' })
    return ""
end

---@param timeout number?
---@return boolean ok
---@return string error
function PlatformManager.stop(timeout)
    if not PlatformManager.started then
        return false, "Not started"
    end
    timeout = timeout or STOP_TIMEOUT
    PlatformManager.scope:cancel('platform manager stopped')

    local source = fibers.perform(op.named_choice {
        join    = PlatformManager.scope:join_op(),
        timeout = sleep.sleep_op(timeout),
    })

    if source == 'timeout' then
        return false, "platform manager stop timeout"
    end
    PlatformManager.started = false
    return true, ""
end

---@param namespaces table
---@return boolean ok
---@return string error
function PlatformManager.apply_config(namespaces) -- luacheck: ignore
    return true, ""
end

return PlatformManager
