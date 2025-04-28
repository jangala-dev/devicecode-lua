-- Importing necessary modules
local fiber = require "fibers.fiber"
local socket = require 'fibers.stream.socket'
local sc = require 'fibers.utils.syscall'
local sleep = require 'fibers.sleep'

local time_service = {
    name = "time"
}
time_service.__index = time_service

-- Define the path for the Unix domain socket
local sockname = '/tmp/ntpd-sock'

local hotplug_handler = [[
# Build the JSON string
JSON_STRING="{\"ACTION\": \"$ACTION\", \"freq_drift_ppm\": \"$freq_drift_ppm\", \"offset\": \"$offset\", \"stratum\": \"$stratum\", \"poll_interval\": \"$poll_interval\"}"

# Launch the Lua script with the JSON string as an argument
luajit /etc/hotplug.d/ntp/socket_send.lua "/tmp/ntpd-sock" "$JSON_STRING"
]]

local socket_send = [[
package.path = "../?.lua;" .. package.path .. ";/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua"

-- Importing necessary modules
local fiber = require "fibers.fiber"
local socket = require 'fibers.stream.socket'

-- Install a polling I/O handler from the fibers library
require("fibers.pollio").install_poll_io_handler()

-- The first argument is the JSON string
local json_str = arg[2]
print(json_str)

-- Define the path for the Unix domain socket
local sockname = arg[1]

fiber.spawn(function ()
    local client = socket.connect_unix(sockname)
    client:setvbuf('no')

    client:write(json_str)

    client:close()
    fiber.stop()
end)

-- Start the main fiber loop
fiber.main()
]]

local function start_ntp_monitor(ctx, sockname)
    -- Remove the socket file if it already exists to avoid 'address already in use' errors
    sc.unlink(sockname)

    -- Create and start listening on the Unix domain socket
    local server = assert(socket.listen_unix(sockname))

    while true do
        -- Accept a new connection
        local peer, err = assert(server:accept())

        if not peer then
            print("Error accepting connection:", err)
            break
        end

        -- Spawn a new fiber for each connection to handle client communication
        fiber.spawn(function()
            while true do
                -- Read a line from the connected client
                local rec = peer:read_line()

                -- If a line is received, process it
                if rec then
                    print("received:", rec)
                else
                    -- If no data is received (client closed the connection), break the loop
                    print("exiting")
                    break
                end
            end
            -- Close the connection to the client
            peer:close()
        end)
    end
    -- After the server is stopped, remove the socket file and stop the fiber
    sc.unlink(sockname)
end

function time_service:start(root_ctx, bus_connection)
    self.bus_connection = bus_connection
end

return time_service
