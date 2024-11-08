local json = require 'dkjson'
local log = require 'log'
local channel = require "fibers.channel"
local fiber   = require "fibers.fiber"
local log = require 'log'
local op   = require 'fibers.op'

MessageHandler = {}
MessageHandler.__index = MessageHandler

function MessageHandler.new(bus_connection, subscription_topic)
    return setmetatable({
        bus_connection = bus_connection,
        subscription_topic = subscription_topic,
        endpoints = {}
    }, MessageHandler)
end

function MessageHandler:create_endpoint(verb, path, handler)
    self.endpoints[verb..':'..path] = {
        handler = handler
    }    
end

function MessageHandler:handle_message_string(msg_string)
    local msg, _, err = json.decode(msg_string)
    if err then 
        log.error(err)
    return end 

    local result = self:execute_messages(msg)
    if result and msg.response_topic then
        self.bus_connection:publish({type="publish", topic=msg.response_topic, payload=result, retained=false})
    end
end

function MessageHandler:execute_messages(msg)
    local verb = msg.verb
    local path = msg.path
    if self.endpoints[verb..':'..path] ~= nil and self.endpoints[verb..':'..path].handler ~= nil then
        return self.endpoints[verb..':'..path]:handler(msg.payload)
    end

    return nil
end

function MessageHandler:start(rootctx)
    self.messaging_quit_channel = channel.new() -- Channel to receive configuration updates

    fiber.spawn(function()
        local sub = self.bus_connection:subscribe(self.subscription_topic)
        local quit
        while not quit do
            op.choice(
                sub:next_msg_op():wrap(function(x) self:handle_message_string(x.payload) end),
                self.messaging_quit_channel:get_op():wrap(function() quit = true end)
            ):perform()
        end
    end)
end

return MessageHandler