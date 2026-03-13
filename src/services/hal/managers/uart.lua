-- HAL modules
local uart_driver = require "services.hal.drivers.uart"
local hal_types = require "services.hal.types.core"

-- Fiber modules
local fibers = require "fibers"
local op = require "fibers.op"
local channel = require "fibers.channel"
local sleep = require "fibers.sleep"

-- Other modules
local log = require "services.log"


-- Constants

local STOP_TIMEOUT = 5.0 -- seconds

---@class UARTManager
---@field scope Scope
---@field started boolean
---@field drivers table<string, UARTDriver>
---@field dev_ev_ch Channel
---@field cap_emit_ch Channel
---@field config_ch Channel
local UARTManager = {
    started   = false,
    drivers   = {},
    config_ch  = channel.new(),
}

--- Stop a driver and emit a removed DeviceEvent.
--- The driver stop is spawned into a fiber so the manager loop is not blocked.
---@param dev_ev_ch Channel
---@param name string
local function on_remove(dev_ev_ch, name)
    local driver = UARTManager.drivers[name]
    if driver == nil then
        log.warn("UART Manager: on_remove called for unknown port:", name)
        return
    end

    log.info("UART Manager: removing port", name)

    -- Stop driver in a spawned fiber — driver:stop blocks on scope join
    fibers.current_scope():spawn(function()
        local ok, stop_err = driver:stop(STOP_TIMEOUT)
        if not ok then
            log.warn("UART Manager: failed to stop driver for", name .. ":", stop_err)
        end
    end)

    UARTManager.drivers[name] = nil

    local device_event, ev_err = hal_types.new.DeviceEvent(
        "removed",
        "uart",
        name
    )
    if not device_event then
        log.error("UART Manager: failed to create removed device event:", ev_err)
        return
    end

    dev_ev_ch:put(device_event)
end

--- Create, initialise, and start a driver for a serial port, then emit an
--- added DeviceEvent. Runs the full lifecycle inside a spawned fiber so the
--- manager loop stays responsive while the driver initialises.
---@param dev_ev_ch Channel
---@param cap_emit_ch Channel
---@param name string
---@param path string
local function on_detection(dev_ev_ch, cap_emit_ch, name, path)
    log.info("UART Manager: creating driver for port", name, "at", path)

    fibers.current_scope():spawn(function()
        local driver, drv_err = uart_driver.new(name, path)
        if not driver then
            log.error("UART Manager: failed to create driver for", name .. ":", drv_err)
            return
        end

        local init_err = driver:init()
        if init_err ~= "" then
            log.error(("UART Manager: failed to init driver for %s: %s"):format(name, init_err))
            return
        end

        local capabilities, cap_err = driver:capabilities(cap_emit_ch)
        if cap_err ~= "" then
            log.error("UART Manager: failed to apply capabilities for", name .. ":", cap_err)
            return
        end

        local ok, start_err = driver:start()
        if not ok then
            log.error("UART Manager: failed to start driver for", name .. ":", start_err)
            return
        end

        UARTManager.drivers[name] = driver

        local device_event, ev_err = hal_types.new.DeviceEvent(
            "added",
            "uart",
            name,
            { path = path },
            capabilities
        )
        if not device_event then
            log.error("UART Manager: failed to create added device event:", ev_err)
            return
        end

        dev_ev_ch:put(device_event)
        log.trace("UART Manager: driver started for port", name)
    end)
end

--- Diff the new config against active drivers and reconcile.
--- Stops drivers whose port is absent or whose path has changed, then starts
--- drivers for any port not already active.
---@param dev_ev_ch Channel
---@param cap_emit_ch Channel
---@param config table
local function apply_drivers(dev_ev_ch, cap_emit_ch, config)
    -- Build a lookup of desired ports from the new config
    local desired = {}
    for _, port_cfg in ipairs(config.serial_ports) do
        desired[port_cfg.name] = port_cfg.path
    end

    -- Stop any active driver that is absent from the new config or has a changed path
    for name, driver in pairs(UARTManager.drivers) do
        if desired[name] == nil or desired[name] ~= driver:get_path() then
            on_remove(dev_ev_ch, name)
        end
    end

    -- Start drivers for ports in the new config that are not yet active
    for _, port_cfg in ipairs(config.serial_ports) do
        if UARTManager.drivers[port_cfg.name] == nil then
            on_detection(dev_ev_ch, cap_emit_ch, port_cfg.name, port_cfg.path)
        end
    end
end

--- Main manager fiber. Handles config application and driver fault recovery in
--- a single select loop, mirroring the modemcard manager pattern.
--- Fault ops are rebuilt from all active drivers on every iteration — when a
--- driver's scope faults its name is returned so on_remove can clean it up.
---@param scope Scope
---@param dev_ev_ch Channel
---@param cap_emit_ch Channel
---@return nil
local function manager(scope, dev_ev_ch, cap_emit_ch)
    log.trace("UART Manager: started")

    scope:finally(function()
        log.trace("UART Manager: closed")
    end)

    while true do
        -- Rebuild fault ops each iteration over all currently active drivers.
        -- op.never() is used as a no-op placeholder when there are no drivers,
        -- keeping the named_choice arm always present.
        local fault_ops = {}
        for name, driver in pairs(UARTManager.drivers) do
            table.insert(fault_ops, driver.scope:fault_op():wrap(function() return name end))
        end

        local fault_op = op.never()
        if #fault_ops > 0 then
            fault_op = op.choice(unpack(fault_ops))
        end

        local source, msg, err = fibers.perform(op.named_choice {
            config       = UARTManager.config_ch:get_op(),
            driver_fault = fault_op,
        })

        if not msg then
            log.error("UART Manager: operation failed:", err)
            break
        end

        if source == "config" then
            apply_drivers(dev_ev_ch, cap_emit_ch, msg)
        elseif source == "driver_fault" then
            log.error("UART Manager: driver fault detected for port", msg)
            on_remove(dev_ev_ch, msg)
        else
            log.error("UART Manager: unknown operation source:", source)
        end
    end
end

--- Starts the UART Manager.
---@param dev_ev_ch Channel
---@param cap_emit_ch Channel
---@return string error
function UARTManager.start(dev_ev_ch, cap_emit_ch)
    if UARTManager.started then
        return "Already started"
    end

    local scope, err = fibers.current_scope():child()
    if not scope then
        return "Failed to create child scope: " .. tostring(err)
    end
    UARTManager.scope      = scope
    UARTManager.dev_ev_ch  = dev_ev_ch
    UARTManager.cap_emit_ch = cap_emit_ch

    -- Log any unexpected scope failure for diagnostics
    scope:finally(function()
        local st, primary = scope:status()
        if st == 'failed' then
            log.error(("UART Manager: error - %s"):format(tostring(primary)))
            log.trace("UART Manager: scope exiting with status", st)
        end
        log.trace("UART Manager: stopped")
    end)

    UARTManager.scope:spawn(manager, dev_ev_ch, cap_emit_ch)

    UARTManager.started = true
    log.trace("UART Manager: started")
    return ""
end

--- Stops the UART Manager.
---@param timeout number? Timeout in seconds
---@return boolean ok
---@return string error
function UARTManager.stop(timeout)
    if not UARTManager.started then
        return false, "Not started"
    end
    timeout = timeout or STOP_TIMEOUT
    UARTManager.scope:cancel()

    local source = fibers.perform(op.named_choice {
        join    = UARTManager.scope:join_op(),
        timeout = sleep.sleep_op(timeout)
    })

    if source == "timeout" then
        return false, "uart manager stop timeout"
    end
    UARTManager.started = false
    return true, ""
end

--- Apply serial port configuration.
--- Puts the config onto config_ch for the manager fiber to process, ensuring
--- config application and fault handling are serialised in one select loop.
---@param config table Expected: { serial_ports = [{name: string, path: string}] }
---@return boolean ok
---@return string error
function UARTManager.apply_config(config)
    if type(config) ~= 'table' or type(config.serial_ports) ~= 'table' then
        return false, "config must contain a serial_ports table"
    end

    if not UARTManager.started then
        return false, "uart manager not started"
    end

    -- Spawn into the manager scope so the put is non-blocking for the caller.
    -- The manager fiber will pick it up when it next loops.
    UARTManager.scope:spawn(function()
        UARTManager.config_ch:put(config)
    end)
    return true, ""
end

return UARTManager
