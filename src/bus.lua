--- The Bus module contains a Bus, Connection and Subscription Class.
---
--- The Bus transports messages by storing topic -> subscriptions mappings in a
--- Trie structure where the topic is the key.
--- When a message is published by a connection the bus retrieves a set of subscriptions
--- from the Trie and pushes the message into each of their queues.
--- Retained messages are stored in a topic -> messages mapping within a Trie structure.
--- Retained messages are pushed to a subscription's queue upon initialisation of such subscription.
-- @module Bus
local queue = require 'fibers.queue'
local op = require 'fibers.op'
local sleep = require 'fibers.sleep'
local trie = require 'trie'
local uuid = require 'uuid'

local DEFAULT_Q_LEN = 10

local CREDS = {
    ['user'] = 'pass',
    ['user1'] = 'pass1',
    ['user2'] = 'pass2',
}

--- A Class for creating operations for message retrieval
--  @type Subscription
local Subscription = {}
Subscription.__index = Subscription

---
-- @tparam Connection connection the connection to the bus
-- @tparam string topic the topic that the subscription is subscribed to
-- @tparam Queue q a queue containing a set of published messages matching the topic
-- @table attributes

--- Create a Subscription to a topic.
-- @tparam Connection conn a Connection to a bus
-- @tparam string topic the topic to subscribe to
-- @tparam Queue q a queue to store messages on
-- @treturn Subscription
function Subscription.new(conn, topic, q)
    return setmetatable({
        connection = conn,
        topic = topic,
        q = q
    }, Subscription)
end

--- Builds an op to either get the next message or timeout.
-- @tparam int timeout how long to wait to recieve a message
-- @treturn ChoiceOp
function Subscription:next_msg_op(timeout)
    local msg_op = op.choice(
        self.q:get_op(),
        timeout and sleep.sleep_op(timeout):wrap(function () return nil, "Timeout" end) or nil
    )
    return msg_op
end

--- Performs a message op.
-- @tparam int timeout how long to wait to receive a message
-- @treturn Any
function Subscription:next_msg(timeout)
    return self:next_msg_op(timeout):perform()
end

--- Closes the subscription.
function Subscription:unsubscribe()
    self.connection:unsubscribe(self.topic, self)
end

--- A Class for creating and storing subscriptions and publishing messages to a bus
--  @type Connection
local Connection = {}
Connection.__index = Connection

---
-- @tparam Bus bus the connected bus
-- @tparam Subscription subscriptions a list of subscriptions associated with this connection
-- @table attributes

--- Creates a Connection to a bus.
-- @tparam Bus bus the Bus to connect to
-- @treturn Connection
function Connection.new(bus)
    return setmetatable({bus = bus, subscriptions = {}}, Connection)
end

--- Sends a message through the Bus.
-- @tparam Message message a message table
-- @return true
function Connection:publish(message)
    self.bus:publish(message)
    return true
end

--- Subscribes to a topic.
-- @tparam string topic
-- @treturn Subscription
-- @treturn Error
function Connection:subscribe(topic)
    local subscription, err = self.bus:subscribe(self, topic)
    if err then return nil, err end
    table.insert(self.subscriptions, subscription)
    return subscription, nil
end

--- Removes a subscription from the connection.
-- @tparam string topic the topic of the subscription
-- @tparam Subscription subscription the subscription to remove
function Connection:unsubscribe(topic, subscription)
    self.bus:unsubscribe(topic, subscription)

    for i, sub in ipairs(self.subscriptions) do -- slow O(n)
        if sub == subscription then
            table.remove(self.subscriptions, i)
            return
        end
    end
end

--- Removes a all subscriptions from a connection.
function Connection:disconnect()
    for _, subscription in ipairs(self.subscriptions) do
        self:unsubscribe(subscription.topic, subscription)
    end
    self.subscriptions = {}
end

--- Publishes a message and creates a subscription to listen to direct replies
-- @tparam Message msg the message to send
-- @treturn Subscription
function Connection:request(msg)
    msg.reply_to = uuid.new()
    local sub = self:subscribe(msg.reply_to)
    self:publish(msg)
    return sub
end

--- The Bus Class transports and stores messages
-- @type Bus
local Bus = {}
Bus.__index = Bus

---
-- @tparam int q_length the length of the message queue
-- @tparam Trie topics a structure of topics mapped to a set of subscriptions
-- @tparam Trie retained_messages a structure of topics mapped to a set of messages
-- @table attributes

--- Creates a new Connection to the bus.
-- @tparam void creds unimplemented
function Bus:connect(creds)
    -- if not Bus:authenticate(creds) then
    --     return nil, 'Authentication failed'
    -- end
    return Connection.new(self)
end

--- Creates a new Subscription to the Bus.
-- @tparam Connection connection the Connection that holds the subscription
-- @tparam string topic the topic to connect to
-- @treturn Subscription
function Bus:subscribe(connection, topic)
    -- get topic from the trie, or make and add to the trie
    local topic_entry, err = self.topics:retrieve(topic)
    if err ~= nil then return nil, err end
    if not topic_entry then
        topic_entry = {subs = {}}
        self.topics:insert(topic, topic_entry)
    end

    -- create the subscription - we have no identity yet, UUID?
    local q = queue.new(self.q_length)
    local subscription = Subscription.new(connection, topic, q)
    table.insert(topic_entry.subs, subscription)

    -- send any relevant retained messages
    for _, v in ipairs(self.retained_messages:match(topic)) do  -- wildcard search in trie
        local put_operation = subscription.q:put_op(v.value)
        put_operation:perform_alt(function ()
            -- print 'QUEUE FULL, not sent' --need to log blocked queue properly
        end)
    end

    return subscription
end

--- Sends a message to a topic defined by message.topic.
-- @tparam Message message the message to send
function Bus:publish(message)
    local matches = self.topics:match(message.topic)
    for _, topic_entry in ipairs(matches) do
        for _, sub in ipairs(topic_entry.value.subs) do
            local put_operation = sub.q:put_op(message)
            put_operation:perform_alt(function ()
                -- TODO: log this properly
            end)
        end
        -- add logic here for nats style q_subs if we go this route
    end

    -- So you can only delete a hold set of messages under a topic? not a specific one?
    if message.retained then
        if not message.payload then  -- send msg with empty payload + ret flag to clear ret message
            self.retained_messages:delete(message.topic)
        else
            self.retained_messages:insert(message.topic, message)
        end
    end
end

--- Removes a Subscription from the Bus
-- @tparam string topic the topic that is subscribed to
-- @tparam Subscription subscription the Subscription to remove
function Bus:unsubscribe(topic, subscription)
    local topic_entry = self.topics:retrieve(topic)
    assert(topic_entry, "error: unsubscribing from a non-existent topic")

    for i, sub in ipairs(topic_entry.subs) do  -- slow O(n)
        if sub == subscription then
            table.remove(topic_entry.subs, i)
        end
    end

    if #topic_entry.subs == 0 then
        self.topics:delete(topic)
    end
end

--- Exported Functions
-- @section exported

--- Create a Bus instance.
-- @function new
-- @param params optional parameters for Bus configurations
-- @param params.q_length the length of the message queues
-- @param params.s_wild the token used to indicate a single line wildcard
-- @param params.m_wild the token used to indicate a multi line wildcard
-- @param params.sep the token to split a topic by within the Trie
-- @treturn Bus
local function new(params)
    params = params or {}
    return setmetatable({
        q_length = params.q_length or DEFAULT_Q_LEN,
        topics = trie.new(params.s_wild, params.m_wild, params.sep), --sets single_wild, multi_wild, separator
        retained_messages = trie.new(params.s_wild, params.m_wild, params.sep)
    }, Bus)
end
return {
    new = new
}

--- Structures
-- @section structures

--- a message is the strucutre used to send information over the Bus
-- @field topic a string indicating where to send the message
-- @field payload the content of the message
-- @field reply_to an identifier of who sent the message (optional)
-- @field retained a flag to indicate if a message should be saved
-- @table Message
