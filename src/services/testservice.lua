local channel = require "fibers.channel"
local fiber   = require "fibers.fiber"
local json = require 'dkjson'
local log = require 'log'
local op   = require 'fibers.op'
local sleep = require 'fibers.sleep'
local file = require 'fibers.stream.file'
local MessageHandler = require 'services.networking.message_handler'
local TelemetryAgent = require 'services.networking.telemetry_agent'

local testservice_service = {}

function testservice_service:health(params)
    return "Health OK from test device with params: " .. json.encode(params)
end

function testservice_service:mental_state(params)
    return "Mental state is great from test device with params: " .. json.encode(params)
end

function testservice_service:hifive()
    return "hifive"
end

function testservice_service:create_message_handler(bus_connection)
    local mh = MessageHandler.new(bus_connection, "testservice/#")

    mh:create_endpoint(
        "post", 
        "hifive",
        self.hifive
    )

    mh:create_endpoint(
        "get", 
        "health",
        self.health
    )

    mh:create_endpoint(
        "get", 
        "mental_state",
        self.mental_state
    )

    return mh
end

function testservice_service:handle_config(msg)
    print("new config received!")
    local config, _, err = json.decode(msg)
    if err then 
        print(err)
    return end -- add proper config error handling

    print("config received for test device")

    if config.telemetry then
        self.telemetry:stop()
        self.telemetry:configure(config.telemetry)
        self.telemetry:run()
    end
end

function testservice_service:start_config_handler()
    fiber.spawn(function()
        local sub = self.bus_connection:subscribe("config/testservice")
        local quit
        while not quit do
            op.choice(
                sub:next_msg_op():wrap(function(x) self:handle_config(x.payload) end),
                self.config_quit_channel:get_op():wrap(function() quit = true end)
            ):perform()
        end

        self.bus_connection:unsubscribe("config/testservice")
    end)
end

function testservice_service:stop_config_handler()
    self.config_quit_channel:put(true)
end

function testservice_service:start(rootctx, bus_connection)
    print("Hello from test device service!")
    self.bus_connection = bus_connection

    self.config_channel = channel.new() -- Channel to receive configuration updates
    self.config_quit_channel = channel.new() -- Channel to receive configuration updates
    self.messaging_quit_channel = channel.new() -- Channel to receive configuration updates

    self.message_handler = self:create_message_handler(bus_connection)
    self.message_handler:start(rootctx)

    self.telemetry = TelemetryAgent.new(self.bus_connection, "t/testservice", self.message_handler)

    self:start_config_handler()
end

return testservice_service