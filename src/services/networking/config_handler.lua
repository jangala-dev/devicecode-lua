local json = require 'dkjson'
local log = require 'log'
local channel = require "fibers.channel"
local fiber   = require "fibers.fiber"
local log = require 'log'
local op   = require 'fibers.op'

ConfigHandler = {}
ConfigHandler.__index = ConfigHandler

function ConfigHandler.new(bus_connection, subscription_topic, config_channel)
    return setmetatable({
        bus_connection = bus_connection,
        subscription_topic = subscription_topic,
        config_channel = config_channel,
        config_quit_channel = channel.new(), -- Channel to receive configuration updates
    }, ConfigHandler)
end

function ConfigHandler:start(rootctx)
    fiber.spawn(function()
        local sub = self.bus_connection:subscribe(self.subscription_topic)
        local quit
        while not quit do
            op.choice(
                sub:next_msg_op():wrap(function(x) 
                    log.info("new config received!")
                    local config, _, err = json.decode(x.payload)
                    if err then 
                        print(err)
                        return 
                    end -- add proper config error handling

                    self.config_channel:put(config) 
                end),
                self.config_quit_channel:get_op():wrap(function() quit = true end)
            ):perform()
        end

        self.bus_connection:unsubscribe(self.subscription_topic)
    end)
end

function ConfigHandler:stop()
    self.config_quit_channel:put(true)
end

return ConfigHandler