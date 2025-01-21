local fiber = require "fibers.fiber"
local utils = require "services.hal.utils"
local assertions = require "test_utils.assertions"

local function check_parse_output(expected, result, err)
    assert(err == nil, "expected err to be nil but got", err)
    assert(result, "expected table but got nil")
    assert(result.type == expected.type,
        'expected type to be ' .. (expected.type or 'nil') .. ' but got ' .. (result.type or "nil"))
    assert(result.reason == expected.reason,
        'expected reason to be ' .. (expected.reason or 'nil') .. ' but got ' .. (result.reason or "nil"))
    assert(result.prev_state == expected.prev_state,
        'expected prev_state to be ' .. (expected.prev_state or 'nil') .. ' but got ' .. (result.prev_state or 'nil'))
    assert(result.curr_state == expected.curr_state,
        'expected curr_state to be ' .. (expected.curr_state or 'nil') .. ' but got ' .. (result.curr_state or 'nil'))
end

local function test_parse_modem_monitor_init()
    local message = "/org/freedesktop/ModemManager1/Modem/0: Initial state, 'disabled'"

    local result, err = utils.parse_modem_monitor(message)
    local expected = {
        type = 'initial',
        reason = nil,
        prev_state = 'disabled',
        curr_state = nil
    }
    check_parse_output(expected, result, err)
end

local function test_parse_modem_monitor_changed_with_reason()
    local message =
        "/org/freedesktop/ModemManager1/Modem/0: State changed, 'disabled' --> 'enabling' (Reason: User request)"

    local result, err = utils.parse_modem_monitor(message)
    local expected = {
        type = 'changed',
        reason = 'User request',
        prev_state = 'disabled',
        curr_state = 'enabling'
    }
    check_parse_output(expected, result, err)
end

local function test_parse_modem_monitor_removed()
    local message = "/org/freedesktop/ModemManager1/Modem/0: Removed"

    local result, err = utils.parse_modem_monitor(message)

    local expected = {
        type = 'removed',
        reason = nil,
        prev_state = nil,
        curr_state = nil
    }
    check_parse_output(expected, result, err)
end

local function test_invalid_parse_modem_monitor()
    local message = "Hello World"

    local result, err = utils.parse_modem_monitor(message)

    assert(err == "Unknown modem monitor message: Hello World",
    'expected "Unknown modem monitor message: Hello World" but received nil ' .. (err or 'nil'))
    assert(result == nil, 'expected nil but got ' .. (result or 'nil'))
end

local function test_nil_parse_modem_monitor()
    local result, err = utils.parse_modem_monitor(nil)

    assert(err == "Modem monitor message is nil",
    'expected "Modem monitor message is nil" but received ' .. (err or 'nil'))
    assert(result == nil, 'expected nil but got ' .. (result or 'nil'))
end

local function test_starts_with_true()
    local main_string = 'this is a test string'
    local start_string = 'this is a'

    local result = utils.starts_with(main_string, start_string)

    local expected_result = true
    assert(result == expected_result, string.format("starts_with expected %s but got %s", expected_result, result))
end

local function test_starts_with_false()
    local main_string = 'this is a test string'
    local start_string = 'this is not a'

    local result = utils.starts_with(main_string, start_string)

    local expected_result = false
    assert(result == expected_result, string.format("starts_with expected %s but got %s", expected_result, result))
end

local function test_starts_with_nil_1()
    local start_string = 'this is a'

    local result = utils.starts_with(nil, start_string)

    local expected_result = false
    assert(result == expected_result, string.format("starts_with expected %s but got %s", expected_result, result))
end

local function test_starts_with_nil_2()
    local main_string = 'this is a test string'

    local result = utils.starts_with(main_string, nil)

    local expected_result = false
    assert(result == expected_result, string.format("starts_with expected %s but got %s", expected_result, result))
end
-- test_parse_monitor_added
local function test_parse_monitor_added()
    local line = '(+) /org/freedesktop/ModemManager1/Modem/1 [QUALCOMM INCORPORATED] QUECTEL Mobile Broadband Module'
    local added, address, err = utils.parse_monitor(line)

    local expected_address = "/org/freedesktop/ModemManager1/Modem/1"
    assert(added == true, 'added should equal true')
    assert(address == expected_address,
        string.format('address expected %s but got %s', expected_address, assertions.to_str(address)))
    assert(err == nil, string.format('expected err to be nil but got %s', assertions.to_str(err)))
end

-- test_parse_monitor_removed

local function test_parse_monitor_removed()
    local line = '(-) /org/freedesktop/ModemManager1/Modem/0 [QUALCOMM INCORPORATED] QUECTEL Mobile Broadband Module'
    local added, address, err = utils.parse_monitor(line)

    local expected_address = "/org/freedesktop/ModemManager1/Modem/0"
    assert(added == false, 'added should equal true')
    assert(address == expected_address,
        string.format('address expected %s but got %s', expected_address, assertions.to_str(address)))
    assert(err == nil, string.format('expected err to be nil but got %s', assertions.to_str(err)))
end

-- test_parse_monitor_nil

local function test_parse_monitor_nil()
    local added, address, err = utils.parse_monitor(nil)

    local expected_err = 'monitor message is nil'

    assert(added == nil, string.format('added should be nil but got %s', assertions.to_str(added)))
    assert(address == nil, string.format('address should be nil but got %s', assertions.to_str(address)))
    assert(err == expected_err, string.format('expected err to be nil but got %s', expected_err, assertions.to_str(err)))
end

-- test_parse_control_topic_valid

local function test_parse_control_topic_valid()
    local topic = 'hal/capability/modem/1/control/enable'

    local cap_name, index, endpoint, err = utils.parse_control_topic(topic)

    local exp_cap_name = 'modem'
    local exp_index = 1
    local exp_endpoint = 'enable'

    assertions.expect_assert(exp_cap_name, cap_name, 'capability name')
    assertions.expect_assert(exp_index, index, 'capability index')
    assertions.expect_assert(exp_endpoint, endpoint, 'capability endpoint')
    assertions.expect_assert(nil, err, 'capability error')
end

-- test_parse_control_topic_fewer_components

local function test_parse_control_topic_fewer_components()
    local topic = 'hal/capability/modem/1/control'

    local cap_name, index, endpoint, err = utils.parse_control_topic(topic)

    local exp_err = 'control topic does not contain enough components'

    assertions.expect_assert(nil, cap_name, 'capability name')
    assertions.expect_assert(nil, index, 'capability index')
    assertions.expect_assert(nil, endpoint, 'capability endpoint')
    assertions.expect_assert(exp_err, err, 'capability error')
end

-- test_parse_control_topic_invalid_number

local function test_parse_control_topic_invalid_number()
    local topic = 'hal/capability/modem/foo/control/enable'

    local cap_name, index, endpoint, err = utils.parse_control_topic(topic)

    local exp_err = 'failed to convert instance to a number'

    assertions.expect_assert(nil, cap_name, 'capability name')
    assertions.expect_assert(nil, index, 'capability index')
    assertions.expect_assert(nil, endpoint, 'capability endpoint')
    assertions.expect_assert(exp_err, err, 'capability error')
end

--
fiber.spawn(function ()
    test_parse_modem_monitor_init()
    test_parse_modem_monitor_changed_with_reason()
    test_parse_modem_monitor_removed()
    test_invalid_parse_modem_monitor()
    test_nil_parse_modem_monitor()

    test_starts_with_true()
    test_starts_with_false()
    test_starts_with_nil_1()
    test_starts_with_nil_2()
    test_parse_monitor_added()
    test_parse_monitor_removed()
    test_parse_monitor_nil()
    test_parse_control_topic_valid()
    test_parse_control_topic_fewer_components()
    test_parse_control_topic_invalid_number()
    fiber.stop()
end)

print("running hal util tests")
fiber.main()
print("passed")
