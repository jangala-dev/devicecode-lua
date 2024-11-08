local json = require 'dkjson'
local log = require 'log'
local file = require 'fibers.stream.file'
local sleep = require 'fibers.sleep'
local mqtt = require 'mosquitto'
local fiber = require 'fibers.fiber'


local MQTTConnection = {
    is_connected = false,
    queue = {first = 0, last = -1, size = 0, max_size = 1000},
    client = nil, 
}

MQTTConnection.__index = MQTTConnection

function MQTTConnection.new_MQTTConnection(broker_ip, user_id, password, topic_data_prefix, topic_control_prefix)
    return setmetatable({
        broker_ip = broker_ip,
        user_id = user_id,
        password = password,
        topic_data_prefix = topic_data_prefix, 
        topic_control_prefix = topic_control_prefix, 
        status = status,
    }, MQTTConnection)
end

function MQTTConnection:initialise()
    mqtt.init()
    local client = mqtt.new()
    self.client = client

    mqttConnection = self

    client:login_set(self.user_id, self.password)
    log.info("user:", self.user_id, "password:", self.password, "broker:", self.broker_ip)
    log.info("Attempting to connect to Mainflux broker")

    if client:connect("0.0.0.0", "1883") ~= true then
        log.error("Failed to connect to Mainflux broker")
    end

    client:callback_set("ON_CONNECT", function()
        log.info("MQTT connected")
        mqttConnection.is_connected = true
        client:subscribe(self.topic_control_prefix.."/#", 2)
    end)

    client:callback_set("ON_MESSAGE", function(mid, topic, payload)
        --print("message", mid, topic, payload)
        local p = json.decode(payload, 1, nil)
        local msg = { topic = string.sub(topic, #self.topic_control_prefix + 2), payload = payload, response_topic = p.response_topic, type = p.type }
        --print("MESSAGE: ", msg.topic, msg.payload, msg.response_topic, msg.type)
        queue = mqttConnection.queue
        queue.last = queue.last + 1
        queue[queue.last] = msg
    end)

    fiber.spawn(function()
        while true do
            client:loop() 
            sleep.sleep(0.1)    
        end
    end)
end

function MQTTConnection:readMsg()
    local result = nil
    if self.queue.first <= self.queue.last then
        result = self.queue[self.queue.first]
        self.queue[self.queue.first] = nil -- to allow garbage collection
        self.queue.first = self.queue.first + 1
        --log.info('Read message: '..result.topic..' '..result.payload)
    end

    return result ~= nil, result    
end

function MQTTConnection:sendMsg(msg)
    if not self.is_connected then
        log.error("Not connected to MQTT broker")
        return
    end
    
    local json_payload = json.encode(msg.payload)
    log.info('Sending message: '..json_payload)
    -- self.client:publish(self.topic_data_prefix..'/'..msg.topic, json_payload)
end

return MQTTConnection