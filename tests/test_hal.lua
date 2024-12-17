package.path = "../src/?.lua;" .. package.path .. ";/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua"
local path = package.path

local fiber = require "fibers.fiber"
local context = require "fibers.context"
local channel = require "fibers.channel"
local op = require "fibers.op"
local sleep = require "fibers.sleep"

local json = require "dkjson"

local core_packages_dir = "../src/?.lua;"
local shim_dir = "./test_hal/shims/"

local function update_shim_path(shim_name)
    package.loaded["services.hal.mmcli"] = nil
    package.path = shim_dir..shim_name.."/?.lua;"..path
end

local function test_monitor_modems()
    update_shim_path("monitor_modems")

    local modem_manager = require "services.hal.modem_manager"
    local modem_manager_instance = modem_manager.new()

    local ctx = context.background()
    local child_ctx = context.with_cancel(ctx)

    local remove_channel = channel.new()
    local detect_channel = channel.new()

    local channel_outputs = {}

    -- modem event listening fiber
    fiber.spawn(function ()
        while not child_ctx:err() do
            op.choice(
                detect_channel:get_op():wrap(function (address)
                    table.insert(channel_outputs, {state="detect", address = address})
                end),
                remove_channel:get_op():wrap(function (address)
                    table.insert(channel_outputs, {state="remove", address = address})
                end),
                child_ctx:done_op()
            ):perform()
        end
    end)

    -- spinning up the detector with a mmcli.lua shim
    fiber.spawn(function ()
        modem_manager_instance:detector(child_ctx, detect_channel, remove_channel)
    end)

    sleep.sleep(1)

    child_ctx:cancel('test over')

    local expected_modem_events = {
        {state = "detect", address = '/org/freedesktop/ModemManager1/Modem/0'},
        {state = "detect", address = '/org/freedesktop/ModemManager1/Modem/1'},
        {state = "remove", address = '/org/freedesktop/ModemManager1/Modem/0'},
        {state = "remove", address = '/org/freedesktop/ModemManager1/Modem/1'}
    }

    for i, event in ipairs(expected_modem_events) do
        assert(event.state==channel_outputs[i].state)
        assert(event.address==channel_outputs[i].address)
    end
end

fiber.spawn(function ()
    test_monitor_modems()
    fiber.stop()
end)

print("running hal tests")
fiber.main()
print("pass")
package.path = path
