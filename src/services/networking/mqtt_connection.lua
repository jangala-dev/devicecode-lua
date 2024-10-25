local json = require 'dkjson'
local log = require 'log'
local file = require 'fibers.stream.file'
local sleep = require 'fibers.sleep'
local mqtt = require 'mosquitto'
local fiber = require 'fibers.fiber'


local MQTTConnection = {
    is_connected = false,
}

local message_queue = {}

MQTTConnection.__index = MQTTConnection

function MQTTConnection.new_MQTTConnection(broker_ip, user_id, password, topic_data_prefix, topic_control_prefix)
    mqtt.init()
    local client = mqtt.new()
    status = { connected = false }

    client.ON_CONNECT = function()
        log.info("MQTT connected")
        log.info("topic_control_prefix: ", topic_control_prefix)
        status.connected = true
        client:subscribe(topic_control_prefix.."/#", 2)
        --  local mid = client:subscribe("channels/"..chanid.."/messages", 2)
    end

    client.ON_MESSAGE = function(mid, topic, payload, qos, retain)
        print(mid, topic, payload, qos, retain)
        local msg = { topic = topic, payload = payload, type = "publish" }
        table.insert(message_queue, msg) -- Replace with a thread safe queue
    end

    client:login_set(user_id, password)
    log.info("user:", user_id, "password:", password, "broker:", broker_ip)
    log.info("Attempting to connect to Mainflux broker")

    if client:connect("localhost", "1883") ~= true then
        log.error("Failed to connect to Mainflux broker")
    end

    fiber.spawn(function()
        while true do
            client:loop() 
            fiber.yield()     
        end
    end)

    return setmetatable({client = client, topic_data_prefix = topic_data_prefix, topic_control_prefix = topic_control_prefix, status = status}, MQTTConnection)
end

function MQTTConnection:readMsg()
    local result = nil
    if #message_queue > 0 then
        result = message_queue[1]
        log.info('Read message: '..result.payload)
        table.remove(message_queue, 1)
    end

    return result ~= nil, result    
end

function MQTTConnection:sendMsg(msg)
    if not self.status.connected then
        log.error("Not connected to MQTT broker")
        return
    end
    
    local json_payload = json.encode(msg.payload)
    log.info('Sending message: '..json_payload)
    -- local extendedtopic = self.topic_prefix..'/'..componentid
    self.client:publish(self.topic_data_prefix..'/'..msg.topic, json_payload)
    -- log.info('Publishing ')--..#metrics..' metrics to topic '..extendedtopic)
end

return MQTTConnection