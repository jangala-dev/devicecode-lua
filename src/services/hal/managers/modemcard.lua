-- HAL modules
local mmcli = require "services.hal.backends.mmcli"
local hal_types = require "services.hal.types.core"
local external_types = require "services.hal.types.external"
local modem_driver = require "services.hal.drivers.modem"

-- Fiber modules
local fibers = require "fibers"
local op = require "fibers.op"
local channel = require "fibers.channel"
local sleep = require "fibers.sleep"

-- Other modules
local log = require "services.log"


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

---Get a modem status and address from a monitor line
---@param line string
---@return boolean? is_added
---@return string? address
---@return string? err
local function parse_monitor(line)
    local status, address = line:match("^(.-)(/org%S+)")
    if address then
        return not status:match("-"), address, nil
    else
        return nil, nil, 'line could not be parsed'
    end
end

---Continuously monitors modem add/remove events and publishes them onto
---`ModemcardManager.modem_detect_ch` and `ModemcardManager.modem_remove_ch`.
---@param scope Scope
local function detector(scope)
    log.trace("Modem Detector: started")

    scope:finally(function ()
        log.trace("Modem Detector: closed")
    end)

    local monitor_cmd = mmcli.monitor_modems()
    local stdout, err = monitor_cmd:stdout_stream()
    if not stdout then
        error("Modem Detector: failed to get stdout stream: " .. err)
    end

    while true do
        local line, rerr = stdout:read_line()
        if rerr then
            log.error("Modem Detector: stdout read error:", rerr)
            break
        end
        if line == nil then
            break
        end

        local is_added, address, parse_err = parse_monitor(line)

        if is_added == nil or address == nil then
            log.error("Modem Detector: failed to parse line:", parse_err)
        elseif is_added == true then
            log.info("Modem Detector: detected at", address)
            ModemcardManager.modem_detect_ch:put(address)
        elseif is_added == false then
            log.info("Modem Detector: removed at", address)
            ModemcardManager.modem_remove_ch:put(address)
        end
    end
end

---Handle modem removal.
---@param dev_ev_ch Channel Device event channel (DeviceEvent messages)
---@param address ModemAddress
local function on_remove(dev_ev_ch, address)
    if type(address) ~= 'string' or address == '' then
        log.error("Modemcard Manager: invalid address on removal")
        return
    end

    log.info("Modemcard Manager: removing modem at", address)

    local driver = ModemcardManager.modems[address]
    if driver == nil then
        log.error("Modemcard Manager: modem not found for removal at", address)
        return
    end

    -- Get device, no need to have a fresh value so set cache lifetime to infinity
    -- Also asking for a fresh value when the modem may have disconnected could cause errors
    local device = driver:get(external_types.new.ModemGetOpts("device", math.huge))

    fibers.current_scope():spawn(function()
        local ok, stop_err = driver:stop(STOP_TIMEOUT)
        if not ok then
            log.error("Modemcard Manager: failed to stop driver:", stop_err)
        end
    end)

    ModemcardManager.modems[address] = nil

    local device_event, ev_err = hal_types.new.DeviceEvent(
        "removed",
        "modemcard",
        device
    )
    if not device_event then
        log.error("Modemcard Manager: failed to create device event:", ev_err)
        return
    end

    dev_ev_ch:put(device_event)
end

---Handle modem detection by creating and initializing a driver.
---@param address ModemAddress
---@return nil
local function on_detection(address)
    if type(address) ~= 'string' or address == '' then
        log.error("Modemcard Manager: invalid address on detection")
        return
    end

    log.info("Modemcard Manager: creating modem at", address)

    local driver, drv_err = modem_driver.new(address)
    if not driver then
        log.error("Modemcard Manager: failed to create modem driver:", drv_err)
        return
    end

    fibers.current_scope():spawn(function()
        local init_err = driver:init()
        if init_err ~= "" then
            log.error(("Modemcard Manager: failed to init modem driver %s: %s"):format(address, init_err))
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
    local device = driver:get(external_types.new.ModemGetOpts("device", math.huge))

    ModemcardManager.modems[driver.address] = driver

    -- Build capabilities
    local capabilities, cap_err = driver:capabilities(cap_emit_ch)
    if cap_err then
        log.error("Modemcard Manager: failed to apply capabilities:", cap_err)
        return
    end

    -- Start the driver
    local ok, start_err = driver:start()
    if not ok then
        log.error("Modemcard Manager: failed to start driver:", start_err)
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
        log.error("Modemcard Manager: failed to create device event:", ev_err)
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
    log.trace("Modemcard Manager: started")

    scope:finally(function ()
        log.trace("Modemcard Manager: closed")
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
            log.error("Modemcard Manager: operation failed:", err)
            break
        end

        if source == "detect" then
            on_detection(msg)
        elseif source == "remove" then
            on_remove(dev_ev_ch, msg)
        elseif source == "driver" then
            on_driver(dev_ev_ch, cap_emit_ch, msg)
        elseif source == "driver_fault" then
            log.error("Modemcard Manager: driver fault detected for modem at", msg)
            on_remove(dev_ev_ch, msg)
        else
            log.error("Modemcard Manager: unknown operation source:", source)
        end
    end
end

---Starts the Modemcard Manager's detector and manager fibers.
---@param dev_ev_ch Channel
---@param cap_emit_ch Channel
---@return string error
function ModemcardManager.start(dev_ev_ch, cap_emit_ch)
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
            log.error(("Modem Manager: error - %s"):format(tostring(primary)))
            log.trace("Modem Manager: scope exiting with status", st)
        end
        log.trace("Modem Manager: stopped")
    end)

    ModemcardManager.scope:spawn(detector)
    ModemcardManager.scope:spawn(manager, dev_ev_ch, cap_emit_ch)

    ModemcardManager.started = true
    log.trace("Modemcard Manager: started")
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

return ModemcardManager
