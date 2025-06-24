local fiber = require "fibers.fiber"
local context = require "fibers.context"
local channel = require "fibers.channel"
local sleep = require "fibers.sleep"
local op = require "fibers.op"
local queue = require "fibers.queue"
local file = require "fibers.stream.file"
local json = require "dkjson"
local bus_pkg = require "bus"
local new_msg = bus_pkg.new_msg
local test_utils = require "test_utils.utils"
local assertions = require "test_utils.assertions"

-- loader makes sure that hal starts from a completely reset state for each test
local hal_loader = test_utils.new_module_loader()
hal_loader:add_uncacheable("services.hal.mmcli")
hal_loader:add_uncacheable("services.hal.modem_driver")
hal_loader:add_uncacheable("services.hal.modem_manager")
hal_loader:add_uncacheable("services.hal")

-- commmon contexts for tests
local function make_contexts()
    local bg_ctx = context.background()
    local service_ctx = context.with_cancel(bg_ctx)
    local fiber_ctx = context.with_cancel(service_ctx)

    return service_ctx, fiber_ctx
end

-- template of a typical device event
local function mock_device_event()
    local info_file, err = file.open('test_modemcard_manager/shims/monitor_modems/services/hal/modemcard_info.json', "r")
    if err then return nil end
    local info_data = info_file:read_all_chars()
    local info = json.decode(info_data)
    return {
        connected = true,
        type = 'usb',
        capabilities = {},
        device_control = {},
        id_field = 'port',
        data = {
            device = 'modemcard',
            port = '/sys/devices/platform/scb/fd500000.pcie/pci0000:00/0000:00:00.0/0000:01:00.0/usb1/1-1/1-1.2',
            info = info
        }
    }
end

local function test_capability_valid_cap()
    local hal = hal_loader:require("services.hal")
    local service_ctx, fiber_ctx = make_contexts()
    local bus = bus_pkg.new({ q_length = 10, m_wild = '#', s_wild = '+', sep = "/" })
    local device_event_q = queue.new()

    fiber.spawn(function()
        hal:control_main(fiber_ctx, bus:connect(), device_event_q)
    end)

    local bus_conn = bus:connect()

    local expected_result = { result = 'success', error = nil }

    -- make a fake capability that returns a simple result
    local caps = {
        modem = {
            control = {
                enable = function()
                    return expected_result
                end},
            info_streams = {}
        }
    }

    local device_event = mock_device_event()
    -- override the capabilities
    device_event.capabilities = caps
    device_event_q:put(device_event)

    sleep.sleep(0.1)

    -- send request for the enable endpoint
    local sub = bus_conn:request(new_msg({ "hal", "capability", "modem", 1, "control", "enable" }, {}))

    -- expect a response from hal with the expected output
    local ret_msg, timeout = sub:next_msg(0.2)

    assert(timeout == nil, 'expected timeout to be nil')
    assertions.assert_table(expected_result, ret_msg.payload, 'cap_result')
    service_ctx:cancel('test-end')
end

-- ask for a capability that does not exist
-- an example of a capability would be modem, time etc
local function test_capability_no_cap()
    local hal = hal_loader:require("services.hal")
    local service_ctx, fiber_ctx = make_contexts()
    local bus = bus_pkg.new({ q_length = 10, m_wild = '#', s_wild = '+', sep = "/" })
    local device_event_q = queue.new()

    fiber.spawn(function()
        hal:control_main(fiber_ctx, bus:connect(), device_event_q)
    end)

    sleep.sleep(0.1)

    local bus_conn = bus:connect()

    local expected_result = { result = nil, error = 'capability does not exist' }

    -- use foo as fake capability
    local sub = bus_conn:request(new_msg({ "hal", "capability", "foo", 1, "control", "enable" }, {}))

    -- expect a response with no result and a capability error
    local ret_msg, timeout = sub:next_msg(0.2)

    assert(timeout == nil, 'expected timeout to be nil')
    assertions.assert_table(expected_result, ret_msg.payload, 'cap_result')
    service_ctx:cancel('test-end')
end

-- use an instance index that does not exist
local function test_capability_no_inst()
    local hal = hal_loader:require("services.hal")
    local service_ctx, fiber_ctx = make_contexts()
    local bus = bus_pkg.new({ q_length = 10, m_wild = '#', s_wild = '+', sep = "/" })
    local device_event_q = queue.new()

    fiber.spawn(function()
        hal:control_main(fiber_ctx, bus:connect(), device_event_q)
    end)

    local bus_conn = bus:connect()

    local expected_result = { result = nil, error = 'capability instance does not exist' }

    local caps = {
        modem = {
            control = {},
            info_streams = {}
        }
    }

    local device_event = mock_device_event()
    device_event.capabilities = caps
    device_event_q:put(device_event)

    sleep.sleep(0.1)

    -- no devices with modem capability have been added yet
    -- so modem instance 100 cannot exist
    local sub = bus_conn:request(new_msg({ "hal", "capability", "modem", 100, "control", "enable" }, {}))

    -- expect a response with no result and a instance error
    local ret_msg, timeout = sub:next_msg(0.2)

    assert(timeout == nil, 'expected timeout to be nil')
    assertions.assert_table(expected_result, ret_msg.payload, 'cap_result')
    service_ctx:cancel('test-end')
end

-- ask for a capability endpoint (or method) that does not exist
local function test_capability_no_method()
    local hal = hal_loader:require("services.hal")
    local service_ctx, fiber_ctx = make_contexts()
    local bus = bus_pkg.new({ q_length = 10, m_wild = '#', s_wild = '+', sep = "/" })
    local device_event_q = queue.new()

    fiber.spawn(function()
        hal:control_main(fiber_ctx, bus:connect(), device_event_q)
    end)

    local bus_conn = bus:connect()

    local expected_result = { result = nil, error = 'endpoint does not exist' }

    local caps = {
        modem = {
            control = {},
            info_streams = {}
        }
    }

    local device_event = mock_device_event()
    device_event.capabilities = caps
    device_event_q:put(device_event)

    sleep.sleep(0.1)

    -- a modem capability has been added with no enpoints so
    -- enable will not exist
    local sub = bus_conn:request(new_msg({ "hal", "capability", "modem", 1, "control", "enable" }, {}))

    -- expect a response with no result and an endpoint error
    local ret_msg, timeout = sub:next_msg(0.2)

    assert(timeout == nil, 'expected timeout to be nil')
    assertions.assert_table(expected_result, ret_msg.payload, 'cap_result')
    service_ctx:cancel('test-end')
end

-- some capabilities may require arguments to be provided to their endpoints
local function test_capability_args()
    local hal = hal_loader:require("services.hal")
    local service_ctx, fiber_ctx = make_contexts()
    local bus = bus_pkg.new({ q_length = 10, m_wild = '#', s_wild = '+', sep = "/" })
    local device_event_q = queue.new()

    fiber.spawn(function()
        hal:control_main(fiber_ctx, bus:connect(), device_event_q)
    end)

    local bus_conn = bus:connect()

    local res1 = 'Hello '
    local res2 = "World"
    local expected_result = { result = res1 .. res2, err = nil }

    -- create a fake capability that takes two strings
    -- and concatenates them
    local caps = {
        modem = {
            control = {
                enable = function(self, args)
                    return { result = args[1] .. args[2], err = nil }
                end
            },
            info_streams = {}
        }
    }

    local device_event = mock_device_event()
    device_event.capabilities = caps
    device_event_q:put(device_event)

    sleep.sleep(0.1)

    -- arguments are supplied in the payload
    local sub = bus_conn:request(new_msg({ "hal", "capability", "modem", 1, "control", "enable" }, { res1, res2 }))

    -- expect a result of the two arguments concatenated
    local ret_msg, timeout = sub:next_msg(0.2)

    assert(timeout == nil, 'expected timeout to be nil')
    assertions.assert_table(expected_result, ret_msg.payload, 'cap_result')
    service_ctx:cancel('test-end')
end

local function test_device_event_add()
    local hal = hal_loader:require("services.hal")
    local service_ctx, fiber_ctx = make_contexts()
    local bus = bus_pkg.new({ q_length = 10, m_wild = '#', s_wild = '+', sep = "/" })
    local device_event_q = queue.new()

    fiber.spawn(function()
        hal:control_main(fiber_ctx, bus:connect(), device_event_q)
    end)

    local bus_conn = bus:connect()

    -- this is the message that is published on the bus
    local expected_result = {
        connected = true,
        type = 'usb',
        index = 1,
        identity = 'modemcard'
    }

    -- send a device connected event, the modem manager would be responsible for this
    local device_event = mock_device_event()
    device_event_q:put(device_event)

    local device_sub = bus_conn:subscribe({ "hal", "device", "usb", "#" })

    -- expect a connection event on the bus
    local device_msg, timeout = device_sub:next_msg(0.2)

    assert(timeout == nil, 'expected timeout to be nil')
    assertions.assert_table(expected_result, device_msg.payload, 'cap_result')
    service_ctx:cancel('test-end')
end

-- the same as above but we add and then remove a device
local function test_device_event_remove()
    local hal = hal_loader:require("services.hal")
    local service_ctx, fiber_ctx = make_contexts()
    local bus = bus_pkg.new({ q_length = 10, m_wild = '#', s_wild = '+', sep = "/" })
    local device_event_q = queue.new()

    fiber.spawn(function()
        hal:control_main(fiber_ctx, bus:connect(), device_event_q)
    end)

    local bus_conn = bus:connect()

    local expected_result = {
        connected = false,
        type = 'usb',
        index = 1,
        identity = 'modemcard'
    }

    local device_event_connect = mock_device_event()
    device_event_q:put(device_event_connect)

    local device_event_disconnect = mock_device_event()
    device_event_disconnect.connected = false
    device_event_q:put(device_event_disconnect)

    sleep.sleep(0.1)

    local device_sub = bus_conn:subscribe({ "hal", "device", "usb", "+" })

    -- no need to worry about the connection message as it will be
    -- overwritten by the disconnection message
    local device_msg, timeout = device_sub:next_msg(0.2)

    assert(timeout == nil, 'expected timeout to be nil')
    assertions.assert_table(expected_result, device_msg.payload, 'cap_result')
    service_ctx:cancel('test-end')
end

local function test_device_event_remove_no_exist()
    local hal = hal_loader:require("services.hal")
    local service_ctx, fiber_ctx = make_contexts()
    local bus = bus_pkg.new({ q_length = 10, m_wild = '#', s_wild = '+', sep = "/" })
    local device_event_q = queue.new()

    fiber.spawn(function()
        hal:control_main(fiber_ctx, bus:connect(), device_event_q)
    end)

    local bus_conn = bus:connect()

    -- remove a device without adding one
    local device_event_disconnect = mock_device_event()
    device_event_disconnect.connected = false
    device_event_q:put(device_event_disconnect)

    sleep.sleep(0.1)

    local device_sub = bus_conn:subscribe({ "hal", "device", "usb", "#" })

    -- hal should not publish anything on the bus, therefore a timeout. A device error log should be printed
    local device_msg, timeout = device_sub:next_msg(0.2)

    assert(timeout == 'Timeout', 'expected message to timeout')
    assert(device_msg == nil, string.format('expected device message to be nil but got %s', device_msg))
    service_ctx:cancel('test-end')
end

-- a device event requires a type (e.g. usb), pass nil instead
local function test_device_event_nil_type()
    local hal = hal_loader:require("services.hal")
    local service_ctx, fiber_ctx = make_contexts()
    local bus = bus_pkg.new({ q_length = 10, m_wild = '#', s_wild = '+', sep = "/" })
    local device_event_q = queue.new()

    fiber.spawn(function()
        hal:control_main(fiber_ctx, bus:connect(), device_event_q)
    end)

    local bus_conn = bus:connect()

    local device_event = mock_device_event()
    device_event.type = nil
    device_event_q:put(device_event)

    sleep.sleep(0.1)

    local device_sub = bus_conn:subscribe({ "hal", "device", "usb", "#" })

    -- hal should not publish anything on the bus, therefore a timeout. A type error log should be printed
    local device_msg, timeout = device_sub:next_msg(0.2)

    assert(timeout == 'Timeout', 'expected message to timeout')
    assert(device_msg == nil, string.format('expected device message to be nil but got %s', device_msg))
    service_ctx:cancel('test-end')
end

local function test_device_event_nil_connected()
    local hal = hal_loader:require("services.hal")
    local service_ctx, fiber_ctx = make_contexts()
    local bus = bus_pkg.new({ q_length = 10, m_wild = '#', s_wild = '+', sep = "/" })
    local device_event_q = queue.new()

    fiber.spawn(function()
        hal:control_main(fiber_ctx, bus:connect(), device_event_q)
    end)

    local bus_conn = bus:connect()

    local device_event = mock_device_event()
    device_event.connected = nil
    device_event_q:put(device_event)

    sleep.sleep(0.1)

    local device_sub = bus_conn:subscribe({ "hal", "device", "usb", "#" })

    -- hal should not publish anything on the bus, therefore a timeout. A connected field error log should be printed
    local device_msg, timeout = device_sub:next_msg(0.2)

    assert(timeout == 'Timeout', 'expected message to timeout')
    assert(device_msg == nil, string.format('expected device message to be nil but got %s', device_msg))
    service_ctx:cancel('test-end')
end

local function test_device_event_nil_id_field()
    local hal = hal_loader:require("services.hal")
    local service_ctx, fiber_ctx = make_contexts()
    local bus = bus_pkg.new({ q_length = 10, m_wild = '#', s_wild = '+', sep = "/" })
    local device_event_q = queue.new()

    fiber.spawn(function()
        hal:control_main(fiber_ctx, bus:connect(), device_event_q)
    end)

    local bus_conn = bus:connect()

    local device_event = mock_device_event()
    device_event.id_field = nil
    device_event_q:put(device_event)

    sleep.sleep(0.1)

    local device_sub = bus_conn:subscribe({ "hal", "device", "usb", "#" })

    -- hal should not publish anything on the bus, therefore a timeout. A identity error log should be printed
    local device_msg, timeout = device_sub:next_msg(0.2)

    assert(timeout == 'Timeout', 'expected message to timeout')
    assert(device_msg == nil, string.format('expected device message to be nil but got %s', device_msg))
    service_ctx:cancel('test-end')
end

local function test_device_event_nil_data()
    local hal = hal_loader:require("services.hal")
    local service_ctx, fiber_ctx = make_contexts()
    local bus = bus_pkg.new({ q_length = 10, m_wild = '#', s_wild = '+', sep = "/" })
    local device_event_q = queue.new()

    fiber.spawn(function()
        hal:control_main(fiber_ctx, bus:connect(), device_event_q)
    end)

    local bus_conn = bus:connect()

    local device_event = mock_device_event()
    device_event.data = nil
    device_event_q:put(device_event)

    sleep.sleep(0.1)

    local device_sub = bus_conn:subscribe({ "hal", "device", "usb", "#" })

    -- hal should not publish anything on the bus, therefore a timeout. A identity error log should be printed
    local device_msg, timeout = device_sub:next_msg(0.2)

    assert(timeout == 'Timeout', 'expected message to timeout')
    assert(device_msg == nil, string.format('expected device message to be nil but got %s', device_msg))
    service_ctx:cancel('test-end')
end

local function test_device_event_nil_capabilities()
    local hal = hal_loader:require("services.hal")
    local service_ctx, fiber_ctx = make_contexts()
    local bus = bus_pkg.new({ q_length = 10, m_wild = '#', s_wild = '+', sep = "/" })
    local device_event_q = queue.new()

    fiber.spawn(function()
        hal:control_main(fiber_ctx, bus:connect(), device_event_q)
    end)

    local bus_conn = bus:connect()

    local device_event = mock_device_event()
    device_event.capabilities = nil
    device_event_q:put(device_event)

    sleep.sleep(0.1)

    local device_sub = bus_conn:subscribe({ "hal", "device", "usb", "#" })

    -- hal should not publish anything on the bus, therefore a timeout. A identity error log should be printed
    local device_msg, timeout = device_sub:next_msg(0.2)

    assert(timeout == 'Timeout', 'expected message to timeout')
    assert(device_msg == nil, string.format('expected device message to be nil but got %s', device_msg))
    service_ctx:cancel('test-end')
end

local function test_capability_event()
    local hal = hal_loader:require("services.hal")
    local service_ctx, fiber_ctx = make_contexts()
    local event_channel = channel.new()
    local bus = bus_pkg.new({ q_length = 10, m_wild = '#', s_wild = '+', sep = "/" })
    local device_event_q = queue.new()

    fiber.spawn(function()
        hal:control_main(fiber_ctx, bus:connect(), device_event_q)
    end)

    local bus_conn = bus:connect()

    local device_event = mock_device_event()
    device_event.capabilities = {
        modem = {
            control = {},
            info_streams = { { name = 'test_event', channel = event_channel, endpoints = 'single' } }
        }
    }

    local expected_event = {
        test = 'event'
    }

    device_event_q:put(device_event)

    sleep.sleep(0.1)

    local event_sub = bus_conn:subscribe({ "hal", "capability", "modem", 1, "info", "test_event" })

    fiber.spawn(function()
        event_channel:put(expected_event)
    end)

    local event_msg, timeout = event_sub:next_msg(0.2)

    assert(timeout == nil, 'event not recieved')
    assertions.assert_table(expected_event, event_msg.payload, 'event_result')
    service_ctx:cancel('test-end')
end
local function test_device_event_nil_identifier()
    local hal = hal_loader:require("services.hal")
    local service_ctx, fiber_ctx = make_contexts()
    local bus = bus_pkg.new({ q_length = 10, m_wild = '#', s_wild = '+', sep = "/" })
    local device_event_q = queue.new()

    fiber.spawn(function()
        hal.control_main(fiber_ctx, bus:connect(), device_event_q)
    end)

    local bus_conn = bus:connect()

    local device_event = mock_device_event()
    device_event.identifier = nil
    device_event_q:put(device_event)

    sleep.sleep(0.1)

    local device_sub = bus_conn:subscribe({ "hal", "device", "usb", "#" })

    -- hal should not publish anything on the bus, therefore a timeout. A identity error log should be printed
    local device_msg, timeout = device_sub:next_msg(0.2)

    assert(timeout == 'Timeout', 'expected message to timeout')
    assert(device_msg == nil, string.format('expected device message to be nil but got %s', device_msg))
    service_ctx:cancel('test-end')
end
local function test_device_info_valid()
    local hal = hal_loader:require("services.hal")
    local service_ctx, fiber_ctx = make_contexts()
    local bus = bus_pkg.new({ q_length = 10, m_wild = '#', s_wild = '+', sep = "/" })
    local device_event_q = queue.new()

    fiber.spawn(function()
        hal:control_main(fiber_ctx, bus:connect(), device_event_q)
    end)

    local bus_conn = bus:connect()

    local expected_result = { result = 0.8, error = nil }

    -- similar to capability, make a fake endpoint
    local device_event = mock_device_event()
    device_event.device_control = {
        utilisation = function()
            return 0.8
        end
    }
    device_event_q:put(device_event)

    sleep.sleep(0.1)

    local info_sub = bus_conn:request(new_msg({ "hal", "device", "usb", "1", "info", "utilisation" }, {}))
    local info_response, timeout = info_sub:next_msg(0.2)

    assert(timeout == nil, 'expected timeout to be nil')
    assertions.assert_table(expected_result, info_response.payload, 'cap_result')
    service_ctx:cancel('test-end')
end

local function test_device_info_no_device_type()
    local hal = hal_loader:require("services.hal")
    local service_ctx, fiber_ctx = make_contexts()
    local bus = bus_pkg.new({ q_length = 10, m_wild = '#', s_wild = '+', sep = "/" })
    local device_event_q = queue.new()

    fiber.spawn(function()
        hal.control_main(fiber_ctx, bus:connect(), device_event_q)
    end)

    local bus_conn = bus:connect()

    local expected_result = { result = nil, error = 'device type does not exist' }

    sleep.sleep(0.1)

    -- there are no supported devices called foo, so we expect an error response
    local info_sub = bus_conn:request(new_msg({ "hal", "device", "foo", "1", "info", "utilisation" }, {}))
    local info_response, timeout = info_sub:next_msg(0.2)

    assert(timeout == nil, 'expected timeout to be nil')
    assertions.assert_table(expected_result, info_response.payload, 'cap_result')
    service_ctx:cancel('test-end')
end

local function test_device_info_no_device()
    local hal = hal_loader:require("services.hal")
    local service_ctx, fiber_ctx = make_contexts()
    local bus = bus_pkg.new({ q_length = 10, m_wild = '#', s_wild = '+', sep = "/" })
    local device_event_q = queue.new()

    fiber.spawn(function()
        hal.control_main(fiber_ctx, bus:connect(), device_event_q)
    end)

    local bus_conn = bus:connect()

    local expected_result = { result = nil, error = 'device does not exist' }

    sleep.sleep(0.1)

    -- no device has been added so usb instance 100 does not exist
    local info_sub = bus_conn:request(new_msg({ "hal", "device", "usb", "100", "info", "utilisation" }, {}))
    local info_response, timeout = info_sub:next_msg(0.2)

    assert(timeout == nil, 'expected timeout to be nil')
    assertions.assert_table(expected_result, info_response.payload, 'cap_result')
    service_ctx:cancel('test-end')
end

local function test_device_info_no_method()
    local hal = hal_loader:require("services.hal")
    local service_ctx, fiber_ctx = make_contexts()
    local bus = bus_pkg.new({ q_length = 10, m_wild = '#', s_wild = '+', sep = "/" })
    local device_event_q = queue.new()

    fiber.spawn(function()
        hal.control_main(fiber_ctx, bus:connect(), device_event_q)
    end)

    local bus_conn = bus:connect()

    local expected_result = { result = nil, error = 'control method does not exist' }

    local device_event = mock_device_event()
    device_event_q:put(device_event)

    sleep.sleep(0.1)

    -- asking for an info endpoint that does not exist
    local info_sub = bus_conn:request(new_msg({ "hal", "device", "usb", "1", "info", "utilisation" }, {}))
    local info_response, timeout = info_sub:next_msg(0.2)

    assert(timeout == nil, 'expected timeout to be nil')
    assertions.assert_table(expected_result, info_response.payload, 'cap_result')
    service_ctx:cancel('test-end')
end

fiber.spawn(function()
    -- main control fiber capability tests
    test_capability_valid_cap()
    test_capability_no_cap()
    test_capability_no_inst()
    test_capability_no_method()
    test_capability_args()

    -- -- main control fiber device event tests
    test_device_event_add()
    test_device_event_remove()
    test_device_event_remove_no_exist()
    test_device_event_nil_type()
    test_device_event_nil_connected()
    test_device_event_nil_id_field()
    test_device_event_nil_data()
    test_device_event_nil_capabilities()

    test_capability_event()
    -- -- main control fiber device info
    -- not running this as kinda redundant for now
    -- test_device_info_valid()
    -- test_device_info_no_device_type()
    -- test_device_info_no_device()
    -- test_device_info_no_method()

    fiber.stop()
end)

print("running hal tests")
fiber.main()
print("tests passed")
