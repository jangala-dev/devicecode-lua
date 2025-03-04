local fiber = require "fibers.fiber"
local sleep = require "fibers.sleep"
local exec = require "fibers.exec"
local context = require "fibers.context"
local driver = require "services.gsm.modem_driver"
local connector = require "services.gsm.connector"
local utils = require "services.gsm.utils"
local channel = require "fibers.channel"
local op = require "fibers.op"
local json = require "dkjson"
local log = require "log"
local new_msg = require "bus".new_msg

local gsm_service = {}
gsm_service.__index = gsm_service

-- Define global channels for inter-component communication

-- Channels for modem events
local modem_config_channel = channel.new()
local modem_detect_channel = channel.new()
local modem_remove_channel = channel.new()

-- Channels for connector events
local connector_config_channel = channel.new()
local connector_modem_association_channel = channel.new()

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

local connectors = {}


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

local function modem_detector(ctx)
    log.trace("GSM: Modem Detector: starting...")

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

local function config_receiver(rootctx, conn)
    log.trace("GSM: Config Receiver: starting...")
    while true do
        local sub = conn:subscribe({ "config", "gsm" })
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

local function modem_manager(ctx)
    log.trace("GSM: Modem Manager starting")

    local modem_config = {}

    local driver_channel = channel.new()

    local function handle_removal(address)
        if not modems.address[address] then return end
        modems.address[address].driver.ctx:cancel('removed')
        modems.address[address] = nil
    end

    local function handle_detection(address)
        local driver = driver.new(context.with_cancel(ctx), address)
        modems.address[address] = new_modem(nil, nil, driver)
        fiber.spawn(function ()
            local err = driver:init()
            if err then
                log.error("GSM: Modem: Handle Detection: modem initialisation failed, removing modem")
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

local function connector_manager(ctx)
    log.trace("GSM: Connector manager starting")

    local connector_config = {}


    local driver_channel = channel.new()
end

local function connector_detector(ctx)
    log.trace("GSM: Connector detector currently unimplemented")
end

function gsm_service:start(ctx, conn)
    log.trace("Starting GSM Service")

    fiber.spawn(function() config_receiver(ctx, conn) end)
    fiber.spawn(function() modem_manager(ctx) end)
    fiber.spawn(function() modem_detector(ctx) end)
    fiber.spawn(function() connector_manager(ctx) end)
    fiber.spawn(function() connector_detector(ctx) end)
end

return gsm_service
