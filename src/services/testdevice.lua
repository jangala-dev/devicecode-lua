local channel = require "fibers.channel"
local fiber   = require "fibers.fiber"
local json = require 'dkjson'
local op   = require 'fibers.op'
local sleep = require 'fibers.sleep'
local file = require 'fibers.stream.file'

local testdevice_service = {}

function testdevice_service:handle_config(msg)
    print("new config received!")
    local conf_received, _, err = json.decode(msg)
    if err then 
        print(err)
    return end -- add proper config error handling

    print("config received for test device")
    local myfile = file.open(conf_received.fd_path, 'a')
    if myfile == nil then
        print("Error opening file")
        return
    end

    fiber.spawn(function()
        while true do
            local msg = string.char(2)..'{"type":"publish","topic":"t.mcu.test","payload":{"n":"test_metric","v":123}}'..string.char(3)
            myfile:write(msg)
            myfile:flush()
            sleep.sleep(conf_received.interval)
        end
    end)
end

function testdevice_service:start_config_handler()
    fiber.spawn(function()
        local sub = self.bus_connection:subscribe("config/testdevice")
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

function testdevice_service:stop_config_handler()
    self.config_quit_channel:put(true)
end

function testdevice_service:start(rootctx, bus_connection)
    print("Hello from test device service!")
    self.bus_connection = bus_connection

    self.config_channel = channel.new() -- Channel to receive configuration updates
    self.config_quit_channel = channel.new() -- Channel to receive configuration updates

    self.testdevice_quit_channel = channel.new() -- Channel to receive configuration updates

    self:start_config_handler()
end

return testdevice_service