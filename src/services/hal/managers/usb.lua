-- services/hal/managers/usb.lua
--
-- USB HAL Manager.
-- Creates a single UsbDriver for the USB 3.0 bus, registers it with HAL,
-- and holds its scope until the manager is stopped.

local usb_driver = require "services.hal.drivers.usb"
local hal_types  = require "services.hal.types.core"

local fibers = require "fibers"
local op     = require "fibers.op"
local sleep  = require "fibers.sleep"

local log = require "services.log"

local STOP_TIMEOUT = 5.0

---@class UsbManager
---@field scope Scope?
---@field started boolean
local UsbManager = {
    started = false,
    scope   = nil,
}

---- manager fiber ----

---@param scope Scope
---@param dev_ev_ch Channel
---@param cap_emit_ch Channel
local function manager(scope, dev_ev_ch, cap_emit_ch)
    log.trace("USB Manager: started")

    scope:finally(function()
        log.trace("USB Manager: closed")
    end)

    local driver, drv_err = usb_driver.new('usb3')
    if not driver then
        error("USB Manager: failed to create USB driver: " .. tostring(drv_err))
    end

    local init_err = driver:init()
    if init_err ~= "" then
        error("USB Manager: failed to init driver: " .. tostring(init_err))
    end

    local capabilities, cap_err = driver:capabilities(cap_emit_ch)
    if cap_err ~= "" then
        error("USB Manager: failed to bind capabilities: " .. tostring(cap_err))
    end

    local ok, start_err = driver:start()
    if not ok then
        error("USB Manager: failed to start driver: " .. tostring(start_err))
    end

    local device_event, ev_err = hal_types.new.DeviceEvent(
        "added", "usb", "usb3", {}, capabilities)
    if not device_event then
        error("USB Manager: failed to create DeviceEvent: " .. tostring(ev_err))
    end
    dev_ev_ch:put(device_event)

    log.trace("USB Manager: device registered")
end

---- public interface ----

---@param dev_ev_ch Channel
---@param cap_emit_ch Channel
---@return string error
function UsbManager.start(dev_ev_ch, cap_emit_ch)
    if UsbManager.started then
        return "Already started"
    end

    local scope, err = fibers.current_scope():child()
    if not scope then
        return "Failed to create child scope: " .. tostring(err)
    end
    UsbManager.scope = scope

    scope:finally(function()
        local st, primary = scope:status()
        if st == 'failed' then
            log.error(("USB Manager: error - %s"):format(tostring(primary)))
        end
        log.trace("USB Manager: stopped")
    end)

    scope:spawn(manager, dev_ev_ch, cap_emit_ch)

    UsbManager.started = true
    log.trace("USB Manager: started")
    return ""
end

---@param timeout number?
---@return boolean ok
---@return string error
function UsbManager.stop(timeout)
    if not UsbManager.started then
        return false, "Not started"
    end
    timeout = timeout or STOP_TIMEOUT
    UsbManager.scope:cancel('usb manager stopped')

    local source = fibers.perform(op.named_choice {
        join    = UsbManager.scope:join_op(),
        timeout = sleep.sleep_op(timeout),
    })

    if source == 'timeout' then
        return false, "usb manager stop timeout"
    end
    UsbManager.started = false
    return true, ""
end

---@param namespaces table
---@return boolean ok
---@return string error
function UsbManager.apply_config(namespaces) -- luacheck: ignore
    return true, ""
end

return UsbManager
