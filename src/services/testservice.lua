local channel = require "fibers.channel"
local fiber   = require "fibers.fiber"
local json = require 'dkjson'
local log = require 'log'
local op   = require 'fibers.op'
local sleep = require 'fibers.sleep'
local file = require 'fibers.stream.file'
local MessageHandler = require 'services.networking.message_handler'
local TelemetryAgent = require 'services.networking.telemetry_agent'
local ConfigHandler = require 'services.networking.config_handler'

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

function testservice_service:handle_config(config)
    if config.telemetry then
        self.telemetry:stop()
        self.telemetry:configure(config.telemetry)
        self.telemetry:run()
    end
end

function testservice_service:start(rootctx, bus_connection)
    print("Hello from test device service!")
    self.bus_connection = bus_connection

    local config_channel = channel.new()
    fiber.spawn(function() while true do 
        local config = config_channel:get()
        self:handle_config(config)
    end end)

    self.config_handler = ConfigHandler.new(bus_connection, "config/testservice", config_channel)
    self.config_handler:start(rootctx)

    self.message_handler = self:create_message_handler(bus_connection)
    self.message_handler:start(rootctx)

    self.telemetry = TelemetryAgent.new(self.bus_connection, "t/testservice", self.message_handler)
end

return testservice_service