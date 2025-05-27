local file = require 'fibers.stream.file'
local fiber = require 'fibers.fiber'
local log = require 'log'
local json = require 'cjson.safe'
local new_msg = require('bus').new_msg

local config_service = {
    name = 'config'
}
config_service.__index = config_service

local function publish_config(ctx, conn)
    -- publish service configs
    local config_file = assert(file.open("configs/" .. ctx:value("device") .. ".json"))
    local raw_config = config_file:read_all_chars()
    local config = json.decode(raw_config)
    for k, v in pairs(config) do
        log.trace("Config: publishing config for: ", k)
        conn:publish(new_msg({ "config", k }, v, { retained = true }))
    end

    -- publish mainflux configs
    local mainflux_config_file = file.open("/data/configs/mainflux.cfg")
    if not mainflux_config_file then
        log.warn("Failed to open mainflux config file, cloud telemetry will not work")
        return
    end
    local raw_mainflux_config = mainflux_config_file:read_all_chars()
    local mainflux_config = json.decode(raw_mainflux_config)
    log.trace("Config: publishing config for: mainflux")
    conn:publish(new_msg({ "config", "mainflux" }, mainflux_config, { retained = true }))
end

function config_service:start(rootctx, conn)
    log.trace("Starting Config Service")

    fiber.spawn(function()
        publish_config(rootctx, conn)
    end)
end

return config_service
