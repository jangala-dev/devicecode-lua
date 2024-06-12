local fiber = require 'fibers.fiber'
local sleep = require 'fibers.sleep'
local json = require 'dkjson'

local dummy_service = {}
dummy_service.__index = dummy_service

function dummy_service:start(rootctx, bus_connection)
    self.bus_connection = bus_connection

    fiber.spawn(function()
        local dummy_examples = {
            {type = "publish", topic = "t.mcu.temp", payload = {n = "temp", v = 19.65}},
            {type = "publish", topic = "t.power", payload = {n = "power", vs = "Connected"}},
            {type = "publish", topic = "t.battery", payload = {n = "battery", vs = "Missing"}},
            {type = "publish", topic = "t.battery", payload = {n = "battery", vs = "Connected"}},
            {type = "publish", topic = "t.battery", payload = {n = "battery", vs = "Charged"}}
        }

        while true do
            for i, dummy_example in pairs(dummy_examples) do
                self.bus_connection:publish({
                    topic=dummy_example.topic, 
                    payload=json.encode(dummy_example), 
                    retained=true
                })
                sleep.sleep(10)
            end
        end
    end)
end

return dummy_service