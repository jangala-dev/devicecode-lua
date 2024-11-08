local fiber = require "fibers.fiber"
local sleep = require "fibers.sleep"
local exec = require "fibers.exec"
local context = require "fibers.context"
local driver = require "services.hal.modem_driver"
local connector = require "services.hal.connector"
local utils = require "services.hal.utils"
local channel = require "fibers.channel"
local op = require "fibers.op"
local json = require "dkjson"
local log = require "log"

local file = require "fibers.stream.file"
local stream = require "fibers.stream"

-- time placeholder
-- local time = require "time"

local hal_service = {}
hal_service.__index = hal_service

-- Define global channels for inter-component communication

-- Channels for modem events
local modem_config_channel = channel.new()
local modem_detect_channel = channel.new()
local modem_remove_channel = channel.new()

-- Channels for connector events
local connector_config_channel = channel.new()
local connector_modem_association_channel = channel.new()

-- device details
local device_settings, err = file.open("./services/hal/device_configs.json", "r")
if err then
    log.error(err)
else
    device_settings = json.decode(device_settings:read_all_chars())
end

-- Containers for holding GSM elements: modems, sims and connectors
local modems = {
    imei = {},
    device = {},
    address = {},
    name = {}
}

local sims = {
    imsi = {},
    iccid = {},
    -- ...
    name = {}
}

local functions = {
    modem = 0,
    geo = 0,
    time = 0
}

local connectors = {}

-- This will hold current available capabilities
local capabilities = {
    modem = {},
    geo = {},
    time = {}
}


-- Defines the Modem type, long-term identities for Modems

local modem = {}
modem.__index = modem

local function new_modem(name, config, driver)
    assert((name and config) or driver)
    local instance = setmetatable({
        name = name,
        config = config,
        driver = driver
    }, modem)
    return instance
end

local function new_modem_capability(driver)
    local ends = {
        enable = driver.enable,
        disable = driver.disable,
        restart = driver.restart,
        connect = driver.connect,
        disconnect = driver.disconnect
    }

    return {
        driver = driver,
        endpoints = ends
    }
end

local function new_geo_capability(driver)
    return {
        driver = driver,
        endpoints = {}
    }
end

local function new_time_capability(driver)
    return {
        driver = driver,
        endpoints = {}
    }
end

function modem:update_config(config)
    self.config = config
    if self.driver then self:apply_config() end
end

function modem:update_driver(driver)
    self.driver = driver
    if self.config then self:apply_config() end
end

function modem:apply_config()
    log.info("Applying configuration for:", self.name)
end

-- Defines the Sim type, long-term identities for Sims
local sim = {}
sim.__index = sim

-- Defines the Connector type, which links modems to sim cards. A modem with a
-- single slot is just a 1x1 instance of a connector.
-- MOVED TO OWN FILE

-- Core module functionality

local function modem_detector(ctx, bus_conn)
    log.trace("HAL: Modem Detector: starting...")

    while true do
        -- First, we start the modem detector
        local cmd = exec.command('mmcli', '-M')
        local stdout = assert(cmd:stdout_pipe())
        local err = cmd:start()
        if err then
            log.error("Failed to start modem detection:", err)
            sleep.sleep(5)
        else
            -- Now we loop over every line of output
            for line in stdout:lines() do
                local is_added, address = utils.parse_monitor(line)

                if is_added==true then
                    log.trace("Modem Detector: detected at:", address)
                    modem_detect_channel:put(address)
                elseif is_added==false then
                    log.trace("Modem Detector: removed at:", address)
                    modem_remove_channel:put(address)
                end
            end
            cmd:wait()
        end
        stdout:close()
    end
end

local function modem_state_monitor(ctx, bus_conn, address, imei)
    log.trace("HAL: starting state monitor for: ", address, "-", imei)
    
    local cmd = exec.command('mmcli', '-m', address, '-w')
    local stdout = assert(cmd:stdout_pipe())
    local err = cmd:start()
    if err then
        log.error(string.format("Modem %s, imei: %s failed to start state monitoring", address, imei))
        sleep.sleep(5)
    else
        while true do
            for line in stdout:lines() do
                log.trace("HAL: detected state change for imei = ", imei)
                local state, _ = utils.parse_modem_monitor(line)
                bus_conn:publish({
                    topic = 'hal/capability/modem/'..imei..'/info/state',
                    payload = state
                })
            end
            cmd:wait()
        end
    end
    stdout:close()
end

local function config_receiver(rootctx, bus_connection)
    log.trace("GSM: Config Receiver: starting...")
    while true do
        local sub = bus_connection:subscribe("config/gsm")
        while true do
            local msg, err = sub:next_msg()
            if err then log.error(err) break end

            local config, _, err = json.decode(msg.payload)
            if err then
                log.error(err)
            else
                log.trace("GSM: Config Receiver: new config received")
                modem_config_channel:put(config.modems)
                connector_config_channel:put(config.connectors)
                -- sim_config_channel:put(config.sims)
            end
        end
        sleep.sleep(1) -- placeholder to prevent multiple rapid restarts
    end
end

local function modem_manager(ctx, bus_conn)
    log.trace("GSM: Modem Manager starting")

    local modem_config = {}

    local driver_channel = channel.new()

    local function handle_removal(address)
        local device = modems.address[address]
        if not device then return end
        device.driver.ctx:cancel('removed')
        modems.address[address] = nil
        local imei = device.driver:imei()
        capabilities.modem[imei] = nil

        -- Remove previously retained message
        bus_conn:publish({
            topic = "hal/device/usb/"..imei,
            payload = "",
            retained = true
        })

        local modem_info = device_settings["modem"][address]
        if modem_info == nil then
            modem_info = device_settings["modem"]["default"]
        end

        -- 
        bus_conn:publish({
            topic = "hal/device/usb/"..imei,
            payload = {
                status = {
                    connected = false,
                    -- "time" = time.now()
                },
                identity = {
                    name = modem_info["name"],
                    model = driver:get_model(),
                    imei = driver:imei()
                },
                capabilities = modem_info["capability"]
            }
        })

        capabilities.modem[imei] = nil
        capabilities.geo[imei] = nil
        capabilities.time[imei] = nil
    end

    local function handle_detection(address)
        local driver = driver.new(context.with_cancel(ctx), address)
        modems.address[address] = new_modem(nil, nil, driver)
        fiber.spawn(function ()
            local err = driver:init()
            if err then
                log.error("GSM: Modem: Handle Detection: modem initialisation failed, removing modem")
                handle_removal(driver)
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
        local model = driver:get_model()
        local address = driver.address

        -- Check if an existing instance for that modem exists
        local instance = modems.imei[imei] or modems.device[device]
        if instance then
            log.trace("GSM: Modem: Handle Driver: driver detected for modem:", instance.name)
            instance:update_driver(driver)
        else
            log.trace("GSM: Modem: Handle Driver: driver detected for unknown modem:", driver.address)
            instance = modems.address[address]
            -- Modem is unknown, insert it into the tables with the relevant keys
            modems.imei[imei] = instance
            modems.device[device] = instance
        end

        local modem_info = device_settings["modem"][address]
        if modem_info == nil then
            modem_info = device_settings["modem"]["default"]
        end

        capabilities.modem[driver:imei()] = new_modem_capability(driver)

        if modem_info["capability"].geo then
            capabilities.geo[driver:imei()] = new_geo_capability(driver)
        end

        if modem_info["capability"].time then
            capabilities.time[driver:imei()] = new_time_capability(driver)
        end

        bus_conn:publish({
            topic = "hal/device/usb/"..imei,
            payload = {
                status = {
                    connected = true,
                    -- "time" = time.now()
                },
                identity = {
                    name = modem_info["name"],
                    model = model,
                    imei = imei
                },
                capabilities = modem_info["capability"]
            },
            retained = true
        })

        fiber.spawn(function () 
            modem_state_monitor(ctx, bus_conn, address, imei)
        end)
    end

    local function handle_config(config)
        modem_config = config

        -- Handling known configs
        for name, mod_config in pairs(config.devices) do
            local instance = modems.name[name]
            if instance then
                instance:update_config(mod_config)
            else
                local id_field = mod_config.id_field
                local id_value = mod_config[id_field]
                instance = modems[id_field] and modems[id_field][id_value]
                if instance then
                    instance.name = name
                    instance:update_config(mod_config)
                else
                    -- Create a new instance and update the modems table
                    instance = new_modem(name, mod_config, nil) -- Driver to be associated later
                    modems.name[name] = instance
                    modems[id_field][id_value] = instance
                end
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

local function control(ctx, bus_conn)
    -- subscribes to all control signals of all capabilities, is this valid?
    local control_sub, err = bus_conn:subscribe("hal/capability/+/+/control/#")
    if err then
        log.error(err)
        return
    end

    while true do
        local err = nil
        local result = nil

        local control_msg = control_sub:next_msg()
        local capability, instance_id, method = utils.parse_control_topic(control_msg.topic)

        local device_driver = capabilities[capability][instance_id]
        if device_driver == nil then
            err = string.format("capability instance %s not found", instance_id)
        else
            local func = device_driver.endpoints[method]
            if func == nil then
                err = string.format("endpoint %s for capability %s does not exist", method, capability)
            else
                result = func(device_driver.driver, unpack(control_msg.payload))
            end
        end

        bus_conn:publish({
            topic = control_msg.reply_to,
            payload = {
                result = result,
                error = err
            }
        })
    end
end

local function connector_manager(ctx)
    log.trace("GSM: Connector manager starting")

    local connector_config = {}


    local driver_channel = channel.new()
end

local function connector_detector(ctx)
    log.trace("GSM: Connector detector currently unimplemented")
end

function hal_service:start(ctx, bus_connection)
    log.trace("Starting HAL Service")

    fiber.spawn(function() control(ctx, bus_connection) end)
    fiber.spawn(function() config_receiver(ctx, bus_connection) end)
    fiber.spawn(function() modem_manager(ctx, bus_connection) end)
    fiber.spawn(function() modem_detector(ctx) end)
    -- fiber.spawn(function() connector_manager(ctx) end)
    -- fiber.spawn(function() connector_detector(ctx) end)
end

return hal_service