local fiber = require "fibers.fiber"
local channel = require "fibers.channel"
local sleep = require "fibers.sleep"
local context = require "fibers.context"
local op = require "fibers.op"
local utils = require "services.hal.utils"
local modem_driver = require "services.hal.modem_driver"
local mmcli = require "services.hal.mmcli"
local service = require "service"
local log = require "log"

local ModemManagement = {
    modem_remove_channel = channel.new(),
    modem_detect_channel = channel.new()
}
ModemManagement.__index = ModemManagement

local function new()
    local modem_management = {}
    return setmetatable(modem_management, ModemManagement)
end

local modems = {}

function ModemManagement:detector(ctx)
    log.trace("Modem Detector: starting...")

    while not ctx:err() do
        -- First, we start the modem detector
        local cmd = mmcli.monitor_modems()
        local stdout = assert(cmd:stdout_pipe())
        local err = cmd:start()

        if err then
            log.error("Failed to start modem detection:", err)
            sleep.sleep(5)
        else
            -- Now we loop over every line of output
            for line in stdout:lines() do
                local is_added, address, parse_err = utils.parse_monitor(line)

                if is_added==true then
                    log.trace("Modem Detector: detected at:", address)
                    self.modem_detect_channel:put(address)
                elseif is_added==false then
                    log.trace("Modem Detector: removed at:", address)
                    self.modem_remove_channel:put(address)
                end
                if parse_err then
                    log.debug(string.format("%s - %s: %s",
                        ctx:value('service_name'),
                        ctx:value('fiber_name'),
                        parse_err))
                end
            end
            cmd:wait()
        end
        stdout:close()
    end
end

function ModemManagement:manager(
    ctx,
    bus_conn,
    device_event_q)
    log.trace("Modem Manager: starting")

    local driver_channel = channel.new()

    local function handle_removal(address)
        local instance = modems[address]
        if not instance then return end
        instance.driver.ctx:cancel('removed')

        modems[address] = nil

        local device = instance.device

        local device_event = {
            connected = false,
            type = 'usb',
            id_field = "port",
            data = {
                device = 'modemcard',
                port = device
            }
        }

        op.choice(
            device_event_q:put_op(device_event),
            ctx:done_op()
        ):perform()
    end

    local function handle_detection(address)
        local driver = modem_driver.new(context.with_cancel(ctx), address)
        fiber.spawn(function ()
            local err = driver:init()
            if err then
                log.error("HAL: Modem: Handle Detection: modem initialisation failed, removing modem")
                handle_removal(address)
            else
                driver_channel:put(driver)
            end
        end)
    end

    local function handle_driver(driver)
        if driver.ctx:err() then return end

        modems[driver.address] = { driver = driver, device = driver.device }

        local capabilities, cap_err = driver:get_capabilities()
        if cap_err then
            log.error(cap_err)
            return
        end
        local device_event = {
            connected = true,
            type = 'usb',
            capabilities = capabilities,
            device_control = {},
            id_field = "port",
            data = {
                device = 'modemcard',
                port = driver.device
            }
        }

        driver:spawn(bus_conn)

        device_event_q:put(device_event)
    end

    while true do
        op.choice(
            self.modem_detect_channel:get_op():wrap(handle_detection),
            self.modem_remove_channel:get_op():wrap(handle_removal),
            driver_channel:get_op():wrap(handle_driver)
        ):perform()
    end
end

function ModemManagement:spawn(ctx, bus_conn, device_event_q)
    service.spawn_fiber('Modem Detector', bus_conn, ctx, function(detector_ctx)
        self:detector(detector_ctx)
    end)

    service.spawn_fiber('Modem Manager', bus_conn, ctx, function(manager_ctx)
        self:manager(manager_ctx, bus_conn, device_event_q)
    end)
end
return {new = new}
