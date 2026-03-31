-- HAL modules
local modem_provider = require "services.hal.backends.modem.provider"
local hal_types = require "services.hal.types.core"
local capability_args = require "services.hal.types.capability_args"
local modem_driver = require "services.hal.drivers.modem"

-- Fiber modules
local fibers = require "fibers"
local op = require "fibers.op"
local channel = require "fibers.channel"
local sleep = require "fibers.sleep"

-- Other modules
local log -- set in start()


-- Constants

local STOP_TIMEOUT = 5.0 -- seconds

---@class ModemDriver

---@class ModemcardManager
---@field scope Scope
---@field started boolean
---@field modem_remove_ch Channel
---@field modem_detect_ch Channel
---@field driver_ch Channel
---@field modems table<ModemAddress, Modem>
local ModemcardManager = {
    started = false,
    modem_remove_ch = channel.new(),
    modem_detect_ch = channel.new(),
    driver_ch = channel.new(),
    modems = {},
}

---Continuously monitors modem add/remove events and publishes them onto
---`ModemcardManager.modem_detect_ch` and `ModemcardManager.modem_remove_ch`.
---@param scope Scope
local function detector(scope)
    log:debug("Modem Detector: started")

    scope:finally(function ()
        log:debug("Modem Detector: closed")
    end)

    local monitor, err = modem_provider.new_monitor()
    if not monitor then
        error("Modem Detector: failed to create monitor: " .. tostring(err))
    end

    while true do
        local event, mon_err = fibers.perform(monitor:next_event_op())
        if mon_err == "Command closed" then
            break
        elseif mon_err and mon_err ~= "" then
            log:warn({ what = 'unparse_monitor_line', err = tostring(mon_err) })
        elseif event then
            ---@cast event ModemMonitorEvent
            if event.is_added then
                log:info({ what = 'modem_detected', address = event.address })
                ModemcardManager.modem_detect_ch:put(event.address)
            else
                log:info({ what = 'modem_removed', address = event.address })
                ModemcardManager.modem_remove_ch:put(event.address)
            end
        end
    end
end

---Handle modem removal.
---@param dev_ev_ch Channel Device event channel (DeviceEvent messages)
---@param address ModemAddress
local function on_remove(dev_ev_ch, address)
    if type(address) ~= 'string' or address == '' then
        log:error({ what = 'invalid_address_removal' })
        return
    end

    log:info({ what = 'removing_modem', address = address })

    local driver = ModemcardManager.modems[address]
    if driver == nil then
        log:error({ what = 'modem_not_found', address = address })
        return
    end

    -- Get device, no need to have a fresh value so set cache lifetime to infinity
    -- Also asking for a fresh value when the modem may have disconnected could cause errors
    local get_ok, primary = driver:get(capability_args.new.ModemGetOpts("device", math.huge))
    if not get_ok then
        log:error({ what = 'get_device_failed', address = address, err = tostring(primary) })
        return
    end
    local device = primary

    fibers.current_scope():spawn(function()
        local ok, stop_err = driver:stop(STOP_TIMEOUT)
        if not ok then
            log:error({ what = 'stop_driver_failed', address = address, err = tostring(stop_err) })
        end
    end)

    ModemcardManager.modems[address] = nil

    local device_event, ev_err = hal_types.new.DeviceEvent(
        "removed",
        "modemcard",
        device
    )
    if not device_event then
        log:error({ what = 'create_device_event_failed', address = address, err = tostring(ev_err) })
        return
    end

    dev_ev_ch:put(device_event)
end

---Handle modem detection by creating and initializing a driver.
---@param address ModemAddress
---@return nil
local function on_detection(address)
    if type(address) ~= 'string' or address == '' then
        log:error({ what = 'invalid_address_detection' })
        return
    end

    log:info({ what = 'creating_modem', address = address })

    local driver, drv_err = modem_driver.new(address, log:child({ modem = address }))
    if not driver then
        log:error({ what = 'create_driver_failed', address = address, err = tostring(drv_err) })
        return
    end

    fibers.current_scope():spawn(function()
        local init_err = driver:init()
        if init_err ~= "" then
            log:error({ what = 'init_driver_failed', address = address, err = init_err })
            return
        end
        ModemcardManager.driver_ch:put(driver)
    end)
end

---Handle a fully initialized driver by creating the modem device, applying
---capabilities, and emitting a HAL device event.
---@param dev_ev_ch Channel Device event channel (DeviceEvent messages)
---@param cap_emit_ch Channel Capability emit channel (Emit messages)
---@param driver Modem
---@return nil
local function on_driver(dev_ev_ch, cap_emit_ch, driver)
    local address = driver.address
    -- Get device, no need to have a fresh value so set cache lifetime to infinity
    local get_ok, primary = driver:get(capability_args.new.ModemGetOpts("device", math.huge))
    if not get_ok then
        log:error({ what = 'get_device_failed', address = address, err = tostring(primary) })
        return
    end
    local device = primary

    ModemcardManager.modems[driver.address] = driver

    -- Build capabilities
    local capabilities, cap_err = driver:capabilities(cap_emit_ch)
    if cap_err then
        log:error({ what = 'apply_capabilities_failed', address = address, err = tostring(cap_err) })
        return
    end

    -- Start the driver
    local ok, start_err = driver:start()
    if not ok then
        log:error({ what = 'start_driver_failed', address = address, err = tostring(start_err) })
        return
    end

    local device_event, ev_err = hal_types.new.DeviceEvent(
        "added",
        "modemcard",
        device,
        {
            address = address,
            port = device -- the device field holds the usb or pcie port info
        },
        capabilities
    )
    if not device_event then
        log:error({ what = 'create_device_event_failed', address = address, err = tostring(ev_err) })
        return
    end

    -- Notify HAL of new modem device
    dev_ev_ch:put(device_event)
end

---Modemcard Manager notifies HAL of modem additions/removals.
---@param scope Scope
---@param dev_ev_ch Channel Device event channel (DeviceEvent messages)
---@param cap_emit_ch Channel Capability emit channel (Emit messages)
---@return nil
local function manager(scope, dev_ev_ch, cap_emit_ch)
    log:debug("Modemcard Manager: started")

    scope:finally(function ()
        log:debug("Modemcard Manager: closed")
    end)

    while true do
        local fault_ops = {}
        for address, driver in pairs(ModemcardManager.modems) do
            table.insert(fault_ops, driver.scope:fault_op():wrap(function () return address end))
        end

        local fault_op = op.never()
        if #fault_ops > 0 then
            fault_op = op.choice(unpack(fault_ops))
        end

        local source, msg, err = fibers.perform(op.named_choice{
            detect = ModemcardManager.modem_detect_ch:get_op(),
            remove = ModemcardManager.modem_remove_ch:get_op(),
            driver = ModemcardManager.driver_ch:get_op(),
            driver_fault = fault_op,
        })

        if not msg then
            log:error({ what = 'operation_failed', err = tostring(err) })
            break
        end

        if source == "detect" then
            on_detection(msg)
        elseif source == "remove" then
            on_remove(dev_ev_ch, msg)
        elseif source == "driver" then
            on_driver(dev_ev_ch, cap_emit_ch, msg)
        elseif source == "driver_fault" then
            log:error({ what = 'driver_fault', address = tostring(msg) })
            on_remove(dev_ev_ch, msg)
        else
            log:error({ what = 'unknown_source', source = tostring(source) })
        end
    end
end

---Starts the Modemcard Manager's detector and manager fibers.
---@param logger Logger
---@param dev_ev_ch Channel
---@param cap_emit_ch Channel
---@return string error
function ModemcardManager.start(logger, dev_ev_ch, cap_emit_ch)
    log = logger
    if ModemcardManager.started then
        return "Already started"
    end

    local scope, err = fibers.current_scope():child()
    if not scope then
        return "Failed to create child scope: " .. tostring(err)
    end
    ModemcardManager.scope = scope

    -- Print out manager stack trace if scope closes on a failure
    scope:finally(function ()
        local st, primary = scope:status()
        if st == 'failed' then
            log:error({ what = 'scope_error', err = tostring(primary) })
            log:debug({ what = 'scope_exit', status = st })
        end
        log:debug("Modem Manager: stopped")
    end)

    ModemcardManager.scope:spawn(detector)
    ModemcardManager.scope:spawn(manager, dev_ev_ch, cap_emit_ch)

    ModemcardManager.started = true
    log:debug("Modemcard Manager: started")
    return ""
end

---Stops the Modemcard Manager.
---@param timeout number? Timeout in seconds
---@return boolean ok
---@return string error
function ModemcardManager.stop(timeout)
    if not ModemcardManager.started then
        return false, "Not started"
    end
    timeout = timeout or STOP_TIMEOUT
    ModemcardManager.scope:cancel()

    local source = fibers.perform(op.named_choice {
        join = ModemcardManager.scope:join_op(),
        timeout = sleep.sleep_op(timeout)
    })

    if source == "timeout" then
        return false, "modemcard manager stop timeout"
    end
    ModemcardManager.started = false
    return true, ""
end

---Apply configuration for modemcard manager (no-op, kept for interface consistency).
---@param namespaces table
---@return boolean ok
---@return string error
function ModemcardManager.apply_config(namespaces) -- luacheck: ignore
    -- No-op: modemcard manager does not support dynamic configuration
    return true, ""
end

return ModemcardManager
