local fiber = require "fibers.fiber"
local json = require 'dkjson'
local op   = require 'fibers.op'
local channel = require 'fibers.channel'
-- local WSTransport = require 'services.networking.ws_transport'
-- local HTTPConnection = require 'services.networking.http_connection'
local FDConnection = require 'services.networking.fd_connection'
--local WSConnection = require 'services.networking.ws_connection'

local Hub = {}
Hub.__index = Hub

local function new_Hub(config, bus_connection)
    return setmetatable({
        bus_connection = bus_connection,
        --ws_transport = WSTransport.new_WSTransport(),
        config = config,
    }, Hub)
end

function Hub:start()
    print("Hub started")
    -- local ws_transport = WSTransport.new_WSTransport(
    --     self.config.ws_host,
    --     self.config.ws_port,
    --     function(conn) self:handle_incoming_connection(WSConnection.new_WSConnection(conn)) end)
    -- ws_transport:run()

    local cid = 1
    for _, cfg in ipairs(self.config.connections) do
        if cfg.type == "http" then
            local http_connection = HTTPConnection.new_HTTPConnection(cfg)
            http_connection.CID = cid
            self:handle_outgoing_connection(http_connection, "t.#")
        elseif cfg.type == "fd" then
            local fd_connection = FDConnection.new_FDConnection(cfg.path_read, cfg.path_send)
            fd_connection.CID = cid
            self:handle_incoming_connection(fd_connection, "t.#")
            self:handle_outgoing_connection(fd_connection, "t.#")
        end

        cid = cid + 1
    end
end

function Hub:handle_outgoing_connection(conn, topic)
    local conn_quit_channel = channel.new() -- Channel to quit connection
    print("New connection")

    local sub = self.bus_connection:subscribe(topic)
    fiber.spawn(function()
        while true do
            local quit
            while not quit do
                op.choice(
                    sub:next_msg_op():wrap(function(x)
                        if x.CID ~= conn.CID then
                            conn:sendMsg(x)
                        end
                    end),
                    conn_quit_channel:get_op():wrap(function() quit = true end)
                ):perform()
            end
        end
    end)
end

function Hub:handle_incoming_connection(conn, topic)
    print("New connection")

    -- if topic ~= nil then
    --     local conn_quit_channel = channel.new() -- Channel to quit connection
    --     fiber.spawn(function()
    --         local sub = self.bus_connection:subscribe(topic)
    --         local quit
    --         while not quit do
    --             op.choice(
    --                 sub:next_msg_op():wrap(function(x) conn:sendMsg(x) end),
    --                 conn_quit_channel:get_op():wrap(function() quit = true end)
    --             ):perform()
    --         end
    --     end)
    -- end

    fiber.spawn(function()
        while true do
            local hasMsg, msg_string = conn:readMsg()

            if hasMsg then
                --print("Got message: ", msg_string)
                local msg, _, err = json.decode(msg_string)
                if err then
                    print(err)
                elseif msg.type == "subscribe" then
                    local conn_quit_channel = channel.new() -- Channel to quit connection
                    fiber.spawn(function()
                        local sub = self.bus_connection:subscribe(msg.topic)
                        local quit
                        while not quit do
                            op.choice(
                                sub:next_msg_op():wrap(function(x) conn:sendMsg(x) end),
                                conn_quit_channel:get_op():wrap(function() quit = true end)
                            ):perform()
                        end
                    end)
                elseif msg.type == "publish" then
                    msg.CID = conn.CID
                    self.bus_connection:publish(msg)
                elseif msg.type == nil then
                    print("No type in message")
                else
                    print("Unknown message type: ", msg.type)
                end
            end

            fiber.yield()
        end
    end)
end

local hub_service = {}

function hub_service:handle_config(msg)
    print("new config received!")
    local conf_received, _, err = json.decode(msg)
    if err then
        print(err)
    return end -- add proper config error handling

    print("config received for hub")
    self.hub = new_Hub(conf_received, self.bus_connection)
    self.hub:start()
end

function hub_service:start_config_handler()
    fiber.spawn(function()
        local sub = self.bus_connection:subscribe("config.hub")
        local quit
        while not quit do
            op.choice(
                sub:next_msg_op():wrap(function(x) self:handle_config(x.payload) end),
                self.config_quit_channel:get_op():wrap(function() quit = true end)
            ):perform()
        end
        -- cleanup code unsubscribe
    end)
end

function hub_service:stop_config_handler()
    self.config_quit_channel:put(true)
end

function hub_service:start(rootctx, bus_connection)
    print("Hello from hub service!")
    self.adapters = {}
    self.bus_connection = bus_connection

    self.config_channel = channel.new() -- Channel to receive configuration updates
    self.config_quit_channel = channel.new() -- Channel to receive configuration updates

    self:start_config_handler()
end

return hub_service
