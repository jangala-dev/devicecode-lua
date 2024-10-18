local fiber = require 'fibers.fiber'
local fiber = require "fibers.fiber"
local op = require "fibers.op"
local pollio = require "fibers.pollio"
local sleep = require "fibers.sleep"
local cqueues = require "cqueues"
local exec = require "fibers.exec"

local websocket = require "http.websocket"
local http_headers = require "http.headers"
local http_server = require "http.server"
local http_util = require "http.util"

print("installing stream based IO library")
require 'fibers.stream.compat'.install()

print("overriding cqueues step")
local old_step; old_step = cqueues.interpose("step", function(self, timeout)
    fiber.yield()
    return old_step(self, 0.0)
end)

local WSTransport = {
    ws_connections = {},
}

WSTransport.__index = WSTransport

function WSTransport.new_WSTransport(host, port, onConnectFunc)
    return setmetatable({
        host = host,
        port = port,
        onConnectFunc = onConnectFunc
    }, WSTransport)
end

function WSTransport:run()
    fiber.spawn(function()
        local myserver = http_server.listen({
            host = self.host,
            port = self.port,
            onstream = function (sv,st)
                print("New connection")
                local ws = websocket.new_from_stream(st, st:get_headers())
                ws:accept()
                self.onConnectFunc(ws)
            end
        })

        myserver:listen()
        while true do
            myserver:step()
            fiber.yield()
        end
    end)
end

return WSTransport