-- services/hal/managers/platform.lua
--
-- Platform HAL Manager.
-- Creates a single PlatformDriver, registers it with HAL, and holds its
-- scope until the manager is stopped.

local platform_driver = require "services.hal.drivers.platform"
local hal_types       = require "services.hal.types.core"

local fibers = require "fibers"
local op     = require "fibers.op"
local sleep  = require "fibers.sleep"

local log = require "services.log"

local STOP_TIMEOUT = 5.0

---@class PlatformManager
---@field scope Scope?
---@field started boolean
local PlatformManager = {
    started = false,
    scope   = nil,
}

---- manager fiber ----

---@param scope Scope
---@param dev_ev_ch Channel
---@param cap_emit_ch Channel
local function manager(scope, dev_ev_ch, cap_emit_ch)
    log.trace("Platform Manager: started")

    scope:finally(function()
        log.trace("Platform Manager: closed")
    end)

    local driver, drv_err = platform_driver.new()
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

    log.trace("Platform Manager: device registered")
end

---- public interface ----

---@param dev_ev_ch Channel
---@param cap_emit_ch Channel
---@return string error
function PlatformManager.start(dev_ev_ch, cap_emit_ch)
    if PlatformManager.started then
        return "Already started"
    end

    local scope, err = fibers.current_scope():child()
    if not scope then
        return "Failed to create child scope: " .. tostring(err)
    end
    PlatformManager.scope = scope

    scope:finally(function()
        local st, primary = scope:status()
        if st == 'failed' then
            log.error(("Platform Manager: error - %s"):format(tostring(primary)))
        end
        log.trace("Platform Manager: stopped")
    end)

    scope:spawn(manager, dev_ev_ch, cap_emit_ch)

    PlatformManager.started = true
    log.trace("Platform Manager: started")
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
