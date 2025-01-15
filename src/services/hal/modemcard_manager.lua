local fiber = require "fibers.fiber"
local channel = require "fibers.channel"
local sleep = require "fibers.sleep"
local context = require "fibers.context"
local op = require "fibers.op"
local service = require "service"
local utils = require "services.hal.utils"
local hal_capabilities = require "services.hal.hal_capabilities"
local modem_driver = require "services.hal.modem_driver"
local mmcli = require "services.hal.mmcli"
local log = require "log"

local ModemManagement = {}
ModemManagement.__index = ModemManagement

local function new()
    local modem_management = {}
    return setmetatable(modem_management, ModemManagement)
end

local ModemCard = {}
ModemCard.__index = ModemCard

function ModemCard.new(name, config, driver)
    return setmetatable({name=name, config=config, driver=driver}, ModemCard)
end

function ModemCard:update_driver(driver)
    self.driver = driver
    self.device = driver:device()
end

function ModemCard:update_config(config)
    self.config = config
end

local modems = {
    -- for short term mmcli level tracking
    address = {},
    -- for semi-perminant tracking
    device = {},
    imei = {},
    name = {}
}

function ModemManagement:detector(ctx, modem_detect_channel, modem_remove_channel)
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
                    modem_detect_channel:put(address)
                elseif is_added==false then
                    log.trace("Modem Detector: removed at:", address)
                    modem_remove_channel:put(address)
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

local function get_device_index(ctx, bus_conn, imei, device)
    local device_sub, err
    local tries = 0
    repeat
        device_sub, err = bus_conn:subscribe('/hal/device/usb/+')
        if err then sleep.sleep(1) end
        tries = tries + 1
    until err == nil or tries == 5

    if err then return nil, err end

    local device_event
    local device_found = false

    repeat
        device_event = op.choice(
            device_sub:next_msg_op(),
            ctx:done_op()
        ):perform()
        if device_event ~= nil
            and device_event.identity.device == 'modemcard'
            and device_event.payload.identity.imei == imei
            and device_event.payload.identity.port == device then
            device_found = true
        end
    until device_found or ctx:err()

    device_sub:unsubscribe()
    if ctx:err() then return nil, string.format("Index not found before: %s", ctx:err()) end
    return device_event.payload.index
end

function ModemManagement:manager(
    ctx,
    bus_conn,
    device_event_q,
    modem_config_channel,
    modem_detect_channel,
    modem_remove_channel)
    log.trace("Modem Manager: starting")

    local modem_config = {}

    local driver_channel = channel.new()

    local function handle_removal(address)
        local instance = modems.address[address]
        if not instance then return end
        instance.driver.ctx:cancel('removed')

        modems.address[address] = nil

        -- Get stale driver information by setting stale flag to true
        local device = instance.driver:get("device", true)
        local imei = instance.driver:get("imei", true)

        local device_event = {
            connected = false,
            type = 'usb',
            identifier = device,
            identity = {
                device = 'modemcard',
                name = instance.name or 'unknown',
                imei = imei,
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

        -- Extract fingerprinting info
        local imei = driver:imei()
        local device = driver:device()

        -- Check if an existing instance for that modem exists
        local instance = modems.imei[imei] or modems.device[device]
        if instance then
            log.trace("HAL: Modem: Handle Driver: driver detected for modem:", instance.name)
            instance:update_driver(driver)
            modems.address[driver.address] = instance
        else
            log.trace("HAL: Modem: Handle Driver: driver detected for unknown modem:", driver.address)
            instance = ModemCard.new(nil, nil, driver)
            -- Modem is unknown, insert it into the tables with the relevant keys
            modems.address[driver.address] = instance
            modems.imei[imei] = instance
            modems.device[device] = instance
        end

        local device_event = {
            connected = true,
            type = 'usb',
            capabilities = {},
            device_control = {},
            identifier = device,
            identity = {
                device = 'modemcard',
                name = instance.name or 'unknown',
                imei = imei,
                port = device
            }
        }

        device_event.capabilities.modem = hal_capabilities.new_modem_capability(driver.command_q)
        if instance.config and instance.config.capabilities then
            if instance.config.capabilities.geo then
                device_event.capabilities.geo = hal_capabilities.new_geo_capability(driver.command_q)
            end
            if instance.config.capabilities.time then
                device_event.capabilities.time = hal_capabilities.new_time_capability(driver.command_q)
            end
        end

        device_event_q:put(device_event)

        fiber.spawn(function()
            local index, err = get_device_index(context.with_timeout(ctx, 5), bus_conn, imei, device)
            if err then
                log.error(string.format("%s - %s: %s", ctx:value("service_name"),
                    ctx:value("fiber_name"), err))
                return
            end

            service.spawn_fiber('State Monitor - ' .. imei, bus_conn, ctx, function()
                driver:monitor_manager(bus_conn, index)
            end)
        end)

        service.spawn_fiber('Command Manger - '..imei, bus_conn, ctx, function ()
            driver:command_manager()
        end)
    end

    local function handle_config(config)
        if config == nil then return end
        if config.known == nil or config.defaults == nil then return end
        modem_config = config

        -- Handling known configs
        for name, mod_config in pairs(config.known) do
            local id_field = mod_config.id_field
            local id_value = mod_config[id_field]
            local instance = modems[id_field] and modems[id_field][id_value]
            if instance then
                instance.name = name
                instance:update_config(mod_config)
            else
                -- Create a new instance and update the modems table
                instance = ModemCard.new(name, mod_config, nil) -- Driver to be associated later
                modems.name[name] = instance
                modems[id_field][id_value] = instance
            end
        end

        -- Apply default configuration to all modems without specific configs
        if modem_config.defaults then
            for _, modem in pairs(modems.address) do
                if not modem.name then
                    log.trace("applying default config to:", modem.address)
                    modem:update_config(modem_config.defaults)
                end
            end
        end
    end

    while true do
        op.choice(
            modem_config_channel:get_op():wrap(handle_config),
            modem_detect_channel:get_op():wrap(handle_detection),
            modem_remove_channel:get_op():wrap(handle_removal),
            driver_channel:get_op():wrap(handle_driver)
        ):perform()
    end
end

return {new = new}
