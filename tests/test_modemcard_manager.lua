local assertions = require "assertions"
local fiber = require "fibers.fiber"
local context = require "fibers.context"
local channel = require "fibers.channel"
local op = require "fibers.op"
local sleep = require "fibers.sleep"
local queue = require "fibers.queue"
local bus_pkg = require "bus"
local test_utils = require "test_utils.utils"
local json = require "dkjson"
local file = require "fibers.stream.file"

local shim_dir = "./test_modemcard_manager/shims/"

-- set module loading to mot cache driver or mmcli for shims
local module_loader = test_utils.new_module_loader()
module_loader:add_uncacheable("services.hal.drivers.modem")
module_loader:add_uncacheable("services.hal.drivers.modem.mmcli")

local function setup_test_contexts()
    local bg_context = context.background()
    local test_context = context.with_cancel(bg_context)
    local fiber_context = context.with_cancel(context.with_value(test_context, "service_name", "dummy-service"))

    return test_context, fiber_context
end

local function make_communication()
    return
        channel.new(), -- detect
        channel.new(), -- remove
        channel.new(), -- config
        queue.new()    -- device events
end

-- Detects 5 Modem events:
--      No modems connected (also invalid parse case),
--      modem detected,
--      modem detected (diff identitiy),
--      modem disconnected,
--      modem disconnected (diff identitiy)
local function test_monitor_modems()
    test_utils.update_shim_path(shim_dir, "monitor_modems")

    local modem_manager = module_loader:require("services.hal.managers.modemcard")
    local modem_manager_instance = modem_manager.new()

    local detect_channel, remove_channel, config_channel, _ = make_communication()
    modem_manager_instance.modem_detect_channel = detect_channel
    modem_manager_instance.modem_remove_channel = remove_channel

    local test_context, fiber_context = setup_test_contexts()

    local channel_outputs = {}

    -- modem event listening fiber
    fiber.spawn(function ()
        while not fiber_context:err() do
            op.choice(
                detect_channel:get_op():wrap(function (address)
                    table.insert(channel_outputs, {state="detect", address = address})
                end),
                remove_channel:get_op():wrap(function (address)
                    table.insert(channel_outputs, {state="remove", address = address})
                end),
                fiber_context:done_op()
            ):perform()
        end
    end)

    -- spinning up the detector with a mmcli.lua shim
    fiber.spawn(function ()
        modem_manager_instance:detector(fiber_context)
    end)

    sleep.sleep(1)

    test_context:cancel('test over')

    local expected_modem_events = {
        {state = "detect", address = '/org/freedesktop/ModemManager1/Modem/0'},
        {state = "detect", address = '/org/freedesktop/ModemManager1/Modem/1'},
        {state = "remove", address = '/org/freedesktop/ModemManager1/Modem/0'},
        {state = "remove", address = '/org/freedesktop/ModemManager1/Modem/1'}
    }

    assertions.assert_table(expected_modem_events, channel_outputs, "modem_events")
    test_context:cancel('test-end')
end

local function test_handle_detection()
    test_utils.update_shim_path(shim_dir, "monitor_modems")

    local modem_manager = module_loader:require("services.hal.managers.modemcard")
    local modem_manager_instance = modem_manager.new()

    local test_context, fiber_context = setup_test_contexts()

    local detect_channel, remove_channel, config_channel, device_event_q = make_communication()
    modem_manager_instance.modem_detect_channel = detect_channel
    modem_manager_instance.modem_remove_channel = remove_channel

    local bus = bus_pkg.new({ q_len = 10, m_wild = '#', s_wild = '+', sep = "/" })

    -- emulate the connection of a modem
    fiber.spawn(function()
        detect_channel:put("address/0")
    end)

    local expected_event = {
        connected = true,
        type = 'usb',
        id_field = 'port',
        data = {
            device = 'modemcard',
            port = "/sys/devices/platform/axi/1000120000.pcie/1f00300000.usb/xhci-hcd.1/usb3/3-1"
        }
    }

    -- spinning up the manager
    fiber.spawn(function()
        modem_manager_instance:manager(fiber_context, bus:connect(), device_event_q)
    end)

    -- listen for device events
    local event = device_event_q:get()

    -- check all fields apart from capabilities
    assertions.assert_table(expected_event, event, "device_event")
    test_context:cancel('test-end')
end

local function test_handle_detection_no_exist()
    test_utils.update_shim_path(shim_dir, "no_device")

    local modem_manager = module_loader:require("services.hal.managers.modemcard")
    local modem_manager_instance = modem_manager.new()

    local test_context, fiber_context = setup_test_contexts()

    local detect_channel, remove_channel, config_channel, device_event_q = make_communication()
    modem_manager_instance.modem_detect_channel = detect_channel
    modem_manager_instance.modem_remove_channel = remove_channel

    local bus = bus_pkg.new({ q_len = 10, m_wild = '#', s_wild = '+', sep = "/" })

    -- emulate the connection of a modem
    fiber.spawn(function()
        detect_channel:put("address/0")
    end)

    -- spinning up the manager
    fiber.spawn(function()
        modem_manager_instance:manager(fiber_context, bus:connect(), device_event_q)
    end)

    -- listen for device events for specific amount of time
    local event = op.choice(
        device_event_q:get_op(),
        sleep.sleep_op(0.5)
    ):perform()

    -- check that nothing was received in time frame
    assert(event == nil, string.format("expected event to be nil but got %s", assertions.to_str(event)))
    test_context:cancel('test-end')
end

local function test_handle_removal()
    test_utils.update_shim_path(shim_dir, "monitor_modems")

    local modem_manager = module_loader:require("services.hal.managers.modemcard")
    local modem_manager_instance = modem_manager.new()

    local test_context, fiber_context = setup_test_contexts()

    local detect_channel, remove_channel, config_channel, device_event_q = make_communication()
    modem_manager_instance.modem_detect_channel = detect_channel
    modem_manager_instance.modem_remove_channel = remove_channel

    local bus = bus_pkg.new({ q_len = 10, m_wild = '#', s_wild = '+', sep = "/" })

    -- emulate the connection and disconnection of a modem
    fiber.spawn(function()
        detect_channel:put('address/0')
        sleep.sleep(0.1)
        remove_channel:put('address/0')
    end)

    local expected_event = {
        connected = false,
        type = 'usb',
        id_field = 'port',
        data = {
            device = 'modemcard',
            port = "/sys/devices/platform/axi/1000120000.pcie/1f00300000.usb/xhci-hcd.1/usb3/3-1"
        }
    }

    -- spinning up the manager
    fiber.spawn(function()
        modem_manager_instance:manager(fiber_context, bus:connect(), device_event_q)
    end)

    -- listen for device events

    local event = device_event_q:get()
    -- We only care about removals
    while event.connected == true do
        event = device_event_q:get()
    end

    -- check all fields apart from capabilities
    assertions.assert_table(expected_event, event, "device_event")
    test_context:cancel('test-end')
end

-- test what happens if we remove a modem which never connected
local function test_handle_removal_no_exist()
    test_utils.update_shim_path(shim_dir, "monitor_modems")

    local modem_manager = module_loader:require("services.hal.managers.modemcard")
    local modem_manager_instance = modem_manager.new()

    local test_context, fiber_context = setup_test_contexts()

    local detect_channel, remove_channel, config_channel, device_event_q = make_communication()
    modem_manager_instance.modem_detect_channel = detect_channel
    modem_manager_instance.modem_remove_channel = remove_channel

    local bus = bus_pkg.new({ q_len = 10, m_wild = '#', s_wild = '+', sep = "/" })

    -- emulate the connection and disconnection of a modem
    fiber.spawn(function()
        remove_channel:put('address/0')
    end)

    -- spinning up the manager
    fiber.spawn(function()
        modem_manager_instance:manager(fiber_context, bus:connect(), device_event_q)
    end)

    -- listen for device events, expect nothing
    local event = op.choice(
        device_event_q:get_op(),
        sleep.sleep_op(0.5)
    ):perform()

    -- check that nothing was recieved
    assert(event == nil, string.format("expected event to be nil but got %s", assertions.to_str(event)))
    test_context:cancel('test-end')
end

fiber.spawn(function ()
    test_monitor_modems()
    test_handle_detection()
    test_handle_detection_no_exist()
    test_handle_removal()
    test_handle_removal_no_exist()
    fiber.stop()
end)

print("running modem card manager tests")
fiber.main()
print("passed")
