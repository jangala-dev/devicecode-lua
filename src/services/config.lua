local file = require 'fibers.stream.file'
local log = require 'log'
local json = require 'dkjson'
local new_msg = require('bus').new_msg

local config_service = {
    name = 'config'
}
config_service.__index = config_service

function config_service:start(rootctx, conn)
    log.trace("Starting Config Service")
    self.conn = conn
    local config_file = assert(file.open("configs/"..rootctx:value("device")..".json"))
    local raw_config = config_file:read_all_chars()
    local config = json.decode(raw_config)
    for k, v in pairs(config) do
        log.trace("Config: publishing config for: ", k)
        self.conn:publish(new_msg({ "config", k }, v, { retained = true }))
    end
end

return config_service
