local file = require 'fibers.stream.file'
local log = require 'log'
local json = require 'dkjson'

local config_service = {}
config_service.__index = config_service

function config_service:start(rootctx, bus_connection)
    log.trace("Starting Config Service")
    self.bus_connection = bus_connection
    local config_file = assert(file.open("configs/"..rootctx:value("device")..".json"))
    local raw_config = config_file:read_all_chars()
    local config = json.decode(raw_config)
    for k, v in pairs(config) do
        log.trace("Config: publishing config for: ", k)
        self.bus_connection:publish({topic="config/"..k, payload=json.encode(v), retained=true})
    end
end

return config_service