local fiber = require "fibers.fiber"
local op = require "fibers.op"
local log = require "log"
local json = require "dkjson"
local exec = require "fibers.exec"

local switch_service = {}
switch_service.__index = switch_service

-- TODO test
local function create_config(config_json)
    local config_str = ""

    for _, item in ipairs(config_json) do
        -- Add the config command
        config_str = config_str .. item.config .. "\n"

        -- Add all the options for this config
        for _, option in ipairs(item.options) do
            config_str = config_str .. "\t" .. option .. "\n"
        end

        config_str = config_str .. "\n"
    end

    return config_str
end

local function write_config(config, path)
    local file, err = io.open(path, "w")

    if not file then
        return err
    end

    file:write(config)
    file:close()
    return nil
end

-- TODO unsure if this is correct command
local function restart_service(service)
    local cmd = exec.command("/etc/init.d/" .. service, 'restart')
    local out, err = cmd:combined_output()

    if err ~= nil then
        return err .. out
    end

    return nil
end

local function set_config(config, path, service)
    local config_str = create_config(config)
    local err = write_config(config_str, path)

    if err ~= nil then
        return err
    end

    err = restart_service(service)
    return err
end

local function config_receiver(bus_connection)
    log.trace("Starting switch config receiver")
    local function handle_config(msg, err)
        if err then
            log.error(err)
            error("Message not received")
        end

        log.trace("Switch config received!")
        local config, _, err = json.decode(msg.payload)
        if err then
            log.error(err)
            error("JSON couldn't be decoded")
        end

        if config["network"] ~= nil then
            fiber.spawn(function()
                log.trace("Network config available")
                local err = set_config(config["network"], "/etc/config/network", "network")

                if err ~= nil then
                    log.error(err)
                else
                    log.trace("Network config set")
                end
            end)
        end

        if config["poe"] ~= nil then
            fiber.spawn(function()
                log.trace("Poe config available")
                local err = set_config(config["poe"], "/etc/config/poe", "network")

                if err ~= nil then
                    log.error(err)
                else
                    log.trace("Poe config set")
                end
            end)
        end
    end

    local sub = bus_connection:subscribe("config/switch")
    while true do
        op.choice(sub:next_msg_op():wrap(handle_config)):perform()
    end
end

function switch_service:start(bus_connection, device_version)
    -- Copy modem set up
    fiber.spawn(function() config_receiver(bus_connection) end)
end

return switch_service
