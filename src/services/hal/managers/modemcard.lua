-- HAL modules
local mmcli = require "services.hal.backends.mmcli"
local hal_types = require "services.hal.types.core"
local modem_types = require "services.hal.types.modem"
local modem_driver = require "services.hal.drivers.modem"

-- Fiber modules
local fibers = require "fibers"
local scope_mod = require "fibers.scope"
local op = require "fibers.op"
local channel = require "fibers.channel"
local sleep = require "fibers.sleep"

-- Other modules
local log = require "services.log"


-- Constants

local STOP_TIMEOUT = 5.0 -- seconds

---@class ModemDriver

---@class ModemcardManager
---@field spawned boolean
---@field modem_remove_ch Channel
---@field modem_detect_ch Channel
---@field driver_ch Channel
---@field modems table<ModemAddress, Modem>
local ModemcardManager = {
    spawned = false,
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
local function detector()
    log.trace("Modem Detector: started")

    local monitor_cmd = mmcli.monitor_modems()
    local stdout, err = monitor_cmd:stdout_stream()
    if not stdout then
        log.error("Modem Detector: failed to open stdout stream:", err)
        log.trace("Modem Detector: closed")
        return
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

    log.trace("Modem Detector: closed")
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

    local identity, id_err = driver:get_identity()
    if not identity then
        log.error("Modemcard Manager: failed to get identity for removal at", address, id_err)
        return
    end
    local device = identity.device

    fibers.spawn(function()
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

    -- Create a child scope for the driver
    local child_scope = fibers.current_scope():child()
    local driver, drv_err = modem_driver.new(child_scope, address)
    if not driver then
        log.error("Modemcard Manager: failed to create modem driver:", drv_err)
        return
    end

    fibers.spawn(function()
        local init_err = driver:init()
        if init_err ~= "" then
            log.error("Modemcard Manager: failed to init modem driver:", init_err)
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
    if getmetatable(driver) ~= modem_driver.ModemDriver then
        log.error("Modemcard Manager: invalid driver received")
        return
    end

    local identity, id_err = driver:get_identity()
    if not identity then
        log.error("Modemcard Manager: failed to get driver identity:", id_err)
        return
    end

    ModemcardManager.modems[identity.address] = driver

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
        identity.device,
        {
            address = identity.address,
            port = identity.device -- the device field holds the usb or pcie port info
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
---@param dev_ev_ch Channel Device event channel (DeviceEvent messages)
---@param cap_emit_ch Channel Capability emit channel (Emit messages)
---@return nil
local function manager(dev_ev_ch, cap_emit_ch)
    log.trace("Modemcard Manager: started")
    while true do
        local source, msg, err = fibers.perform(op.named_choice {
            detect = ModemcardManager.modem_detect_ch:get_op(),
            remove = ModemcardManager.modem_remove_ch:get_op(),
            driver = ModemcardManager.driver_ch:get_op(),
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
        end
    end

    log.trace("Modemcard Manager: closed")
end

---Starts the Modemcard Manager's detector and manager fibers.
---@param scope Scope
---@param dev_ev_ch Channel
---@param cap_emit_ch Channel
function ModemcardManager.start(scope, dev_ev_ch, cap_emit_ch)
    if ModemcardManager.spawned then
        log.warn("Modemcard Manager: already spawned")
        return
    end

    ModemcardManager.scope = scope

    scope:spawn(detector)
    scope:spawn(manager, dev_ev_ch, cap_emit_ch)

    ModemcardManager.spawned = true
    log.trace("Modemcard Manager: spawned")
end

---Stops the Modemcard Manager.
---@param timeout number? Timeout in seconds
---@return boolean ok
---@return string error
function ModemcardManager.stop(timeout)
    timeout = timeout or STOP_TIMEOUT
    ModemcardManager.scope:cancel()

    local source = fibers.perform(op.named_choice {
        join = ModemcardManager.scope:join_op(),
        timeout = sleep.sleep_op(timeout)
    })

    if source == "timeout" then
        return false, "modemcard manager stop timeout"
    end
    return true, ""
end
