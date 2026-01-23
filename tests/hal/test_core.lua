-- Detect if this file is being run as the entry point
local this_file = debug.getinfo(1, "S").source:match("@?([^/]+)$")
local is_entry_point = arg and arg[0] and arg[0]:match("[^/]+$") == this_file

if is_entry_point then
	-- Match the test harness package.path setup (see tests/test.lua,
	-- test_wifi.lua, test_metrics.lua, test_system.lua)
	package.path = "../../src/lua-fibers/?.lua;" -- fibers submodule src
		.. "../../src/lua-trie/src/?.lua;"    -- trie submodule src
		.. "../../src/lua-bus/src/?.lua;"     -- bus submodule src
		.. "../../src/?.lua;"                 -- main src tree
		.. "../../?.lua;"                     -- repo root (for tests.hal.harness)
		.. "./test_utils/?.lua;"              -- shared test utilities
		.. package.path
		.. ";/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua;"
		.. "./harness/?.lua;"

	_G._TEST = true -- Enable test exports in source code
	local log = require 'services.log'
	local rxilog = require 'rxilog'
	for _, mode in ipairs(rxilog.modes) do
		log[mode.name] = function() end -- no-op logging during tests
	end
end

local luaunit = require 'luaunit'
local fiber = require 'fibers.fiber'
local unpack = unpack or table.unpack

local harness = require 'tests.hal.harness'

-- Test harness for HAL configuration, device events, and capability events.

-- HAL config tests

TestHalConfig = {}

local new_hal_env = harness.new_hal_env
local config_path = harness.config_path
local publish_config = harness.publish_config

local function assert_no_managers(hal, msg)
	luaunit.assertNil(next(hal.managers), msg or "Expected HAL to have zero managers")
end

function TestHalConfig:test_simple_config()
	local hal, ctx, bus, conn, new_msg = new_hal_env()

	local test_arg = "test"
	local config = { -- spawns a dummy manager with a test arg
		managers = {
			dummy = {
				test_arg = test_arg
			},
		},
	}

	-- Subscribe before starting HAL to avoid races with the
	-- initial status publication from the dummy manager.
	local dummy_manager_sub = conn:subscribe({ "dummy", "status" })

	hal:start(ctx, bus:connect())

	publish_config(conn, new_msg, config)
	luaunit.assertNotNil(dummy_manager_sub, "Expected to subscribe to dummy manager status messages")
	local msg, err = harness.wait_for_msg(dummy_manager_sub, ctx)
	luaunit.assertNil(err, "Expected to receive dummy manager status message")
	luaunit.assertNotNil(msg, "Expected to receive dummy manager status message")
	luaunit.assertEquals(msg.payload, "running")
	luaunit.assertNotNil(hal.managers.dummy, "Expected HAL to have instantiated dummy manager")
	luaunit.assertEquals(hal.managers.dummy.test_arg, test_arg, "Expected dummy manager to have applied config")
	ctx:cancel("test complete")
end

function TestHalConfig:test_nil_config()
	local hal, ctx, bus, conn, new_msg = new_hal_env()

	local config = nil

	hal:start(ctx, bus:connect())

	publish_config(conn, new_msg, config)

	local ok, reason = harness.wait_until(ctx, function()
		return next(hal.managers) ~= nil
	end)
	luaunit.assertFalse(ok, "Expected HAL to not create managers for nil config")
	assert_no_managers(hal)
	ctx:cancel("test complete")
end

function TestHalConfig:test_empty_managers_config()
	local hal, ctx, bus, conn, new_msg = new_hal_env()

	local config = {
		managers = {
			-- empty managers
		},
	}

	hal:start(ctx, bus:connect())

	publish_config(conn, new_msg, config)

	local ok, reason = harness.wait_until(ctx, function()
		return next(hal.managers) ~= nil
	end)
	luaunit.assertFalse(ok, "Expected HAL to not create managers for empty managers config")
	assert_no_managers(hal)
	ctx:cancel("test complete")
end

function TestHalConfig:test_invalid_type_config()
	local hal, ctx, bus, conn, new_msg = new_hal_env()

	local config = "This should be a table, not a string"

	hal:start(ctx, bus:connect())

	publish_config(conn, new_msg, config)

	local ok, reason = harness.wait_until(ctx, function()
		return next(hal.managers) ~= nil
	end)
	luaunit.assertFalse(ok, "Expected HAL to not create managers for invalid type config")
	assert_no_managers(hal)
	ctx:cancel("test complete")
end

function TestHalConfig:test_no_managers_config()
	local hal, ctx, bus, conn, new_msg = new_hal_env()

	local config = {
		-- no managers key
		some_other_config = true
	}

	hal:start(ctx, bus:connect())

	publish_config(conn, new_msg, config)

	local ok, reason = harness.wait_until(ctx, function()
		return next(hal.managers) ~= nil
	end)
	luaunit.assertFalse(ok, "Expected HAL to not create managers when managers key is missing")
	assert_no_managers(hal)
	ctx:cancel("test complete")
end

function TestHalConfig:test_invalid_manager()
	local hal, ctx, bus, conn, new_msg = new_hal_env()

	local config = {
		managers = {
			invalid_manager_name = {
				some_arg = "some_value"
			},
		},
	}

	hal:start(ctx, bus:connect())

	publish_config(conn, new_msg, config)

	local ok, reason = harness.wait_until(ctx, function()
		return hal.managers.invalid_manager_name ~= nil
	end)
	luaunit.assertFalse(ok, "Expected HAL to ignore invalid manager name")
	luaunit.assertNil(hal.managers.invalid_manager_name, "Expected HAL to ignore invalid manager name")
	ctx:cancel("test complete")
end

function TestHalConfig:test_remove_manager()
	local hal, ctx, bus, conn, new_msg = new_hal_env()

	local test_arg = "test"
	local config = {
		managers = {
			dummy = {
				test_arg = test_arg
			},
		},
	}

	local dummy_manager_sub = conn:subscribe({ "dummy", "status" })

	hal:start(ctx, bus:connect())

	publish_config(conn, new_msg, config)
	luaunit.assertNotNil(dummy_manager_sub, "Expected to subscribe to dummy manager status messages")
	local msg, err = harness.wait_for_msg(dummy_manager_sub, ctx)
	luaunit.assertNil(err, "Expected to receive dummy manager status message" .. (err and (": " .. tostring(err)) or ""))
	luaunit.assertNotNil(msg, "Expected to receive dummy manager status message")
	luaunit.assertEquals(msg.payload, "running")
	luaunit.assertNotNil(hal.managers.dummy, "Expected HAL to have instantiated dummy manager")

	local done = false
	local dummy_ctx = hal.managers.dummy.ctx
	fiber.spawn(function()
		dummy_ctx:done_op():perform()
		done = true
	end)

	-- Now remove the dummy manager from HAL

	local new_config = {
		managers = {
			-- empty managers
		},
	}

	conn:publish(
		new_msg(
			config_path(),
			new_config,
			{ retained = true }
		)
	)

	local ok, reason = harness.wait_until(ctx, function()
		return (next(hal.managers) == nil or hal.managers.dummy == nil) and done
	end)
	luaunit.assertTrue(ok, "Expected HAL to remove dummy manager, but wait_until failed: " .. tostring(reason))
	luaunit.assertNil(hal.managers.dummy, "Expected HAL to have removed dummy manager")
	luaunit.assertNil(next(hal.managers), "Expected HAL to have zero managers")
	luaunit.assertTrue(done, "Expected dummy manager context to be done") -- manager should revieve a cancel signal
	ctx:cancel("test complete")
end

function TestHalConfig:test_reconfigure_manager()
	local hal, ctx, bus, conn, new_msg = new_hal_env()

	local test_arg = "initial_value"
	local config = {
		managers = {
			dummy = {
				test_arg = test_arg
			},
		},
	}

	-- Subscribe before starting HAL so we reliably see the
	-- initial status message published by the dummy manager.
	local dummy_manager_sub = conn:subscribe({ "dummy", "status" })
	luaunit.assertNotNil(dummy_manager_sub, "Expected to subscribe to dummy manager status messages")

	hal:start(ctx, bus:connect())

	publish_config(conn, new_msg, config)

	local msg, err = harness.wait_for_msg(dummy_manager_sub, ctx)
	luaunit.assertNil(err, "Expected to receive dummy manager status message")
	luaunit.assertNotNil(msg, "Expected to receive dummy manager status message")
	luaunit.assertEquals(msg.payload, "running")
	luaunit.assertNotNil(hal.managers.dummy, "Expected HAL to have instantiated dummy manager")
	luaunit.assertEquals(hal.managers.dummy.test_arg, test_arg, "Expected dummy manager to have applied initial config")

	-- Now reconfigure the dummy manager

	local new_test_arg = "updated_value"
	local new_config = {
		managers = {
			dummy = {
				test_arg = new_test_arg
			},
		},
	}

	conn:publish(
		new_msg(
			config_path(),
			new_config,
			{ retained = true }
		)
	)

	local ok, reason = harness.wait_until(ctx, function()
		return hal.managers.dummy ~= nil and hal.managers.dummy.test_arg == new_test_arg
	end)
	luaunit.assertTrue(ok,
		"Expected HAL to reconfigure dummy manager, but wait_until failed: " .. tostring(reason))
	luaunit.assertNotNil(hal.managers.dummy, "Expected HAL to still have dummy manager after reconfiguration")
	luaunit.assertEquals(hal.managers.dummy.test_arg, new_test_arg,
		"Expected dummy manager to have applied updated config")
	ctx:cancel("test complete")
end

function TestHalConfig:test_invalid_config_does_not_affect_managers()
	local hal, ctx, bus, conn, new_msg = new_hal_env()

	local test_arg = "initial_value"
	local config = {
		managers = {
			dummy = {
				test_arg = test_arg
			},
		},
	}

	local dummy_manager_sub = conn:subscribe({ "dummy", "status" })

	hal:start(ctx, bus:connect())

	publish_config(conn, new_msg, config)
	luaunit.assertNotNil(dummy_manager_sub, "Expected to subscribe to dummy manager status messages")
	local msg, err = harness.wait_for_msg(dummy_manager_sub, ctx)
	luaunit.assertNil(err, "Expected to receive dummy manager status message")
	luaunit.assertNotNil(msg, "Expected to receive dummy manager status message")
	luaunit.assertEquals(msg.payload, "running")
	luaunit.assertNotNil(hal.managers.dummy, "Expected HAL to have instantiated dummy manager")
	luaunit.assertEquals(hal.managers.dummy.test_arg, test_arg, "Expected dummy manager to have applied initial config")

	-- Now publish an invalid config type

	local invalid_config = "This should be a table, not a string"

	publish_config(conn, new_msg, invalid_config)

	local ok, reason = harness.wait_until(ctx, function()
		return next(hal.managers) == nil
	end)
	luaunit.assertFalse(ok, "Expected HAL to keep dummy manager after invalid config")
	luaunit.assertNotNil(hal.managers.dummy, "Expected HAL to still have dummy manager after invalid config")
	luaunit.assertEquals(hal.managers.dummy.test_arg, test_arg,
		"Expected dummy manager to retain initial config after invalid config")

	-- Now publish a missing managers config
	local missing_managers_config = {
		some_other_config = true
	}
	publish_config(conn, new_msg, missing_managers_config)

	ok, reason = harness.wait_until(ctx, function()
		return next(hal.managers) == nil
	end)
	luaunit.assertFalse(ok, "Expected HAL to keep dummy manager after missing managers config")
	luaunit.assertNotNil(hal.managers.dummy, "Expected HAL to still have dummy manager after missing managers config")
	luaunit.assertEquals(hal.managers.dummy.test_arg, test_arg,
		"Expected dummy manager to retain initial config after missing managers config")

	ctx:cancel("test complete")
end

function TestHalConfig:test_partial_manager_removal()
	local hal, ctx, bus, conn, new_msg = new_hal_env()

	local config = {
		managers = {
			dummy = {
				test_arg = "value1"
			},
			dummy2 = {
				test_arg = "value2"
			},
		},
	}

	local dummy_manager_sub = conn:subscribe({ "dummy", "status" })
	local dummy2_manager_sub = conn:subscribe({ "dummy2", "status" })

	hal:start(ctx, bus:connect())

	publish_config(conn, new_msg, config)

	-- Wait for dummy manager 1
	luaunit.assertNotNil(dummy_manager_sub, "Expected to subscribe to dummy manager status messages")
	local msg, err = harness.wait_for_msg(dummy_manager_sub, ctx)
	luaunit.assertNil(err, "Expected to receive dummy manager status message")
	luaunit.assertNotNil(msg, "Expected to receive dummy manager status message")
	luaunit.assertEquals(msg.payload, "running")
	luaunit.assertNotNil(hal.managers.dummy, "Expected HAL to have instantiated dummy manager")

	-- Wait for dummy manager 2
	luaunit.assertNotNil(dummy2_manager_sub, "Expected to subscribe to dummy2 manager status messages")
	local msg2, err2 = harness.wait_for_msg(dummy2_manager_sub, ctx)
	luaunit.assertNil(err2, "Expected to receive dummy2 manager status message")
	luaunit.assertNotNil(msg2, "Expected to receive dummy2 manager status message")
	luaunit.assertEquals(msg2.payload, "running")
	luaunit.assertNotNil(hal.managers.dummy2, "Expected HAL to have instantiated dummy2 manager")

	-- Now remove only the dummy2 manager by omitting it from
	-- the new config while keeping dummy present.
	local new_config = {
		managers = {
			dummy = {
				test_arg = "value2"
			},
		},
	}
	conn:publish(
		new_msg(
			config_path(),
			new_config,
			{ retained = true }
		)
	)

	local ok, reason = harness.wait_until(ctx, function()
		return hal.managers.dummy ~= nil and hal.managers.dummy.test_arg == "value2" and
			hal.managers.dummy2 == nil
	end)
	luaunit.assertTrue(ok,
		"Expected HAL to apply partial manager removal, but wait_until failed: " .. tostring(reason))
	-- HAL removes managers that are not present in the new
	-- config, so dummy2 should be removed and dummy kept.
	luaunit.assertNotNil(hal.managers.dummy, "Expected HAL to still have dummy manager")
	luaunit.assertEquals(hal.managers.dummy.test_arg, "value2", "Expected dummy manager to have applied updated config")
	luaunit.assertNil(hal.managers.dummy2, "Expected HAL to have removed dummy2 manager")
	ctx:cancel("test complete")
end

-- Device event tests

TestHalDeviceEvent = {}

local function make_dummy_device_event(connected, id, capabilities)
	return {
		connected = connected,
		type = 'dummy_device',
		id_field = "field",
		data = {
			field = id
		},
		capabilities = connected and capabilities or nil, -- only present on connected
		device_control = connected and {} or nil,
	}
end

local function device_event_path(device_type, device_id)
	return { 'hal', 'device', device_type, device_id }
end

local function assert_no_device_event(device_event_q, hal_device_event_sub, ctx, event, description)
	device_event_q:put(event)
	local msg, err = harness.wait_for_msg(hal_device_event_sub, ctx)
	luaunit.assertNil(msg,
		"Expected to not receive HAL device event message for " .. description)
	luaunit.assertEquals(err, 'timeout',
		"Expected timeout when no HAL device event should be received for " .. description ..
			", got: " .. tostring(err))
end

function TestHalDeviceEvent:test_device_add_event()
	local hal, ctx, bus, conn, new_msg = new_hal_env()
	hal:start(ctx, bus:connect())
	local device_event_q = hal.device_event_q
	local device_name = 'dummy1'
	local device_add_event = make_dummy_device_event(true, device_name, {})

	local hal_device_event_sub = conn:subscribe(device_event_path('dummy_device', device_name))

	device_event_q:put(device_add_event)

	-- Next wait for a device event and check the value in the payload
	local msg, err = harness.wait_for_msg(hal_device_event_sub, ctx)
	luaunit.assertNil(err, "Expected to receive HAL device event message")
	luaunit.assertNotNil(msg, "Expected to receive HAL device event message")
	luaunit.assertNotNil(msg.payload, "Expected HAL device event message to have data payload")
	luaunit.assertEquals(msg.payload.connected, true, "Expected device connected state to be true")
	luaunit.assertEquals(msg.payload.type, 'dummy_device', "Expected device type to be 'dummy_device'")
	luaunit.assertEquals(msg.payload.index, device_name, "Expected device id to match")
	ctx:cancel("test complete")
end

function TestHalDeviceEvent:test_device_remove_event()
	local hal, ctx, bus, conn, new_msg = new_hal_env()
	hal:start(ctx, bus:connect())
	local device_event_q = hal.device_event_q
	local device_name = 'dummy2'
	local device_add_event = make_dummy_device_event(true, device_name, {})
	local device_remove_event = make_dummy_device_event(false, device_name, nil)

	local hal_device_event_sub = conn:subscribe(device_event_path('dummy_device', device_name))

	device_event_q:put(device_add_event)
	device_event_q:put(device_remove_event)

	-- First wait for the add event to be received
	local msg, err = harness.wait_for_msg(hal_device_event_sub, ctx)
	luaunit.assertNil(err, "Expected to receive HAL device event message")
	luaunit.assertNotNil(msg, "Expected to receive HAL device event message")
	luaunit.assertNotNil(msg.payload, "Expected HAL device event message to have data payload")
	luaunit.assertEquals(msg.payload.connected, true, "Expected device connected state to be true")

	-- Now wait for the remove event and check the value in the payload
	local msg, err = harness.wait_for_msg(hal_device_event_sub, ctx)
	luaunit.assertNil(err, "Expected to receive HAL device event message")
	luaunit.assertNotNil(msg, "Expected to receive HAL device event message")
	luaunit.assertNotNil(msg.payload, "Expected HAL device event message to have data payload")
	luaunit.assertEquals(msg.payload.connected, false, "Expected device connected state to be false")
	luaunit.assertEquals(msg.payload.type, 'dummy_device', "Expected device type to be 'dummy_device'")
	luaunit.assertEquals(msg.payload.index, device_name, "Expected device id to match")
	ctx:cancel("test complete")
end

function TestHalDeviceEvent:test_device_remove_nonexistent()
	local hal, ctx, bus, conn, new_msg = new_hal_env()
	hal:start(ctx, bus:connect())
	local device_event_q = hal.device_event_q
	local device_name = 'dummy3'
	local device_remove_event = make_dummy_device_event(false, device_name, nil)

	local hal_device_event_sub = conn:subscribe(device_event_path('dummy_device', device_name))

	assert_no_device_event(device_event_q, hal_device_event_sub, ctx, device_remove_event, 'nonexistent device')
	ctx:cancel("test complete")
end

function TestHalDeviceEvent:test_device_add_event_invalid()
	local hal, ctx, bus, conn, new_msg = new_hal_env()
	hal:start(ctx, bus:connect())
	local device_event_q = hal.device_event_q
	local device_name = 'dummy_invalid'

	local hal_device_event_sub = conn:subscribe(device_event_path('dummy_device', device_name))

	-- Each invalid event starts from a helper-generated valid event
	-- and then removes exactly one required field.

	-- No type field
	local event_no_type = make_dummy_device_event(true, device_name, {})
	event_no_type.type = nil
	assert_no_device_event(device_event_q, hal_device_event_sub, ctx, event_no_type, 'invalid event: no type field')

	-- No connected field
	local event_no_connected = make_dummy_device_event(true, device_name, {})
	event_no_connected.connected = nil
	assert_no_device_event(device_event_q, hal_device_event_sub, ctx, event_no_connected,
		'invalid event: no connected field')

	-- No id_field field
	local event_no_id_field = make_dummy_device_event(true, device_name, {})
	event_no_id_field.id_field = nil
	assert_no_device_event(device_event_q, hal_device_event_sub, ctx, event_no_id_field,
		'invalid event: no id_field field')

	-- No data field
	local event_no_data = make_dummy_device_event(true, device_name, {})
	event_no_data.data = nil
	assert_no_device_event(device_event_q, hal_device_event_sub, ctx, event_no_data, 'invalid event: no data field')

	-- No capabilities field (for a connected device)
	local event_no_capabilities = make_dummy_device_event(true, device_name, {})
	event_no_capabilities.capabilities = nil
	assert_no_device_event(device_event_q, hal_device_event_sub, ctx, event_no_capabilities,
		'invalid event: no capabilities field')

	ctx:cancel('test complete')
end

-- Capability event tests

TestHalDeviceCapabilityEvent = {}

local function wrap_result(...)
	return { result = { ... }, err = nil }
end

local function wrap_error(err_msg)
	return { result = nil, err = err_msg }
end

local function make_dummy_capability_list(length)
	local capabilities = {}
	for i = 1, length do
		local cap = {
			id = tostring(i),
			control = {
				no_args = function()
					return wrap_result(i, "no_args_endpoint")
				end,
				single_arg = function(_, args)
					return wrap_result(i, "single_arg_endpoint", args, #args)
				end,
				multi_arg = function(_, args)
					return wrap_result(i, "multi_arg_endpoint", args, #args)
				end,
				error_fn = function()
					return wrap_error("Capability function error")
				end
			}
		}
		capabilities["capability" .. i] = cap
	end
	return capabilities
end

local function assert_capability_event(event, expected_event)
	luaunit.assertNotNil(event, "Expected capability event to not be nil")
	luaunit.assertEquals(event.connected, expected_event.connected, "Expected capability connected state to match")
	luaunit.assertEquals(event.type, expected_event.type, "Expected capability type to match")
	luaunit.assertEquals(event.index, expected_event.index, "Expected capability index to match")
	luaunit.assertNotNil(event.device, "Expected capability event to have device field")
	luaunit.assertEquals(event.device.type, expected_event.device.type, "Expected capability device type to match")
	luaunit.assertEquals(event.device.index, expected_event.device.index, "Expected capability device index to match")
end

local function make_expected_capability_event(device_name, capability_index, connected)
	return {
		connected = connected,
		type = "capability" .. capability_index,
		index = tostring(capability_index),
		device = {
			type = "dummy_device",
			index = device_name,
		},
	}
end

local function capability_event_path(capability_index)
	-- Topic used by HAL for capability connection events generated
	-- as a side effect of device connection events.
	return { 'hal', 'capability', 'capability' .. capability_index, tostring(capability_index) }
end

local function all_capability_event_path()
	-- Topic used by HAL for all capability connection events
	return { 'hal', 'capability', '+', '+' }
end

local function expect_capability_event(sub, ctx, expected_event, label)
	local suffix = label and (" " .. label) or ""
	local msg, err = harness.wait_for_msg(sub, ctx)
	luaunit.assertNil(err, "Expected to receive HAL capability event message" .. suffix)
	luaunit.assertNotNil(msg, "Expected to receive HAL capability event message" .. suffix)
	assert_capability_event(msg.payload, expected_event)
end

local function assert_no_capability_event(ctx, sub, label)
	local suffix = label and (" " .. label) or ""
	local msg, err = harness.wait_for_msg(sub, ctx)
	luaunit.assertNil(msg, "Expected to not receive HAL capability event message" .. suffix)
	luaunit.assertEquals(err, 'timeout', "Expected timeout when no capability event should be received" .. suffix ..
		", got: " .. tostring(err))
end

local function expect_retained_drop_event(ctx, sub)
	local msg, err = harness.wait_for_msg(sub, ctx)
	luaunit.assertNil(err, "Expected to receive a message")
	luaunit.assertNotNil(msg, "Expected to receive a message")
	luaunit.assertNil(msg.payload, "Expected retained drop message to have nil payload")
end


function TestHalDeviceCapabilityEvent:test_device_capability_add_event()
	local hal, ctx, bus, conn, new_msg = new_hal_env()
	hal:start(ctx, bus:connect())
	local device_name = 'dummy_capable_device'
	local capabilities = make_dummy_capability_list(1)
	local device_event = make_dummy_device_event(true, device_name, capabilities)
	local hal_capability_info_sub = conn:subscribe(capability_event_path(1))
	hal.device_event_q:put(device_event)

	local expected_event = make_expected_capability_event(device_name, 1, true)

	-- Next wait for a capability event and check the value in the payload
	expect_capability_event(hal_capability_info_sub, ctx, expected_event, "for capability1")
	ctx:cancel("test complete")
end

function TestHalDeviceCapabilityEvent:test_device_no_capability()
	local hal, ctx, bus, conn, new_msg = new_hal_env()
	hal:start(ctx, bus:connect())
	local device_name = 'dummy_no_capability_device'
	local capabilities = {} -- empty capabilities
	local device_event = make_dummy_device_event(true, device_name, capabilities)
	local hal_capability_info_sub = conn:subscribe(all_capability_event_path())

	hal.device_event_q:put(device_event)

	-- No capability event should be published
	assert_no_capability_event(ctx, hal_capability_info_sub,
		"Expect no capability events for device with no capabilities")

	ctx:cancel("test complete")
end

function TestHalDeviceCapabilityEvent:test_device_multi_capability_event()
	local hal, ctx, bus, conn, new_msg = new_hal_env()
	hal:start(ctx, bus:connect())
	local device_name = 'dummy_multi_capable_device'
	local capabilities = make_dummy_capability_list(3)
	local device_event = make_dummy_device_event(true, device_name, capabilities)
	local subs = {}
	for i = 1, 3 do
		subs[i] = conn:subscribe(capability_event_path(i))
	end

	hal.device_event_q:put(device_event)

	-- Next wait for capability info events and check the values in the payloads
	for i, sub in ipairs(subs) do
		local expected_event = make_expected_capability_event(device_name, i, true)
		expect_capability_event(sub, ctx, expected_event, "for capability" .. i)
	end

	ctx:cancel("test complete")
end

function TestHalDeviceCapabilityEvent:test_device_capability_remove_event()
	local hal, ctx, bus, conn, new_msg = new_hal_env()
	hal:start(ctx, bus:connect())
	local device_name = 'dummy_capable_device_remove'
	local capabilities = make_dummy_capability_list(1)
	local device_add_event = make_dummy_device_event(true, device_name, capabilities)
	local device_remove_event = make_dummy_device_event(false, device_name, nil)
	local hal_capability_info_sub = conn:subscribe(capability_event_path(1))

	hal.device_event_q:put(device_add_event)

	local expected_add_event = make_expected_capability_event(device_name, 1, true)

	-- Next wait for a capability info add event and check the value in the payload
	expect_capability_event(hal_capability_info_sub, ctx, expected_add_event, "for capability1 add")

	-- Now send the remove event
	hal.device_event_q:put(device_remove_event)

	local expected_remove_event = make_expected_capability_event(device_name, 1, false)

	-- A nil payload is sent first to remove retained values under the topic
	expect_retained_drop_event(ctx, hal_capability_info_sub)

	-- Next wait for a capability info remove event and check the value in the payload
	expect_capability_event(hal_capability_info_sub, ctx, expected_remove_event, "for capability1 remove")

	ctx:cancel("test complete")
end

function TestHalDeviceCapabilityEvent:test_device_capability_invalid_event()
	local hal, ctx, bus, conn, new_msg = new_hal_env()
	hal:start(ctx, bus:connect())
	local device_name = 'dummy_invalid_capability_device'

	-- Start from two valid capabilities, then invalidate one of them
	local capabilities = make_dummy_capability_list(2)
	capabilities["capability2"].id = nil -- missing id should make this capability invalid

	local device_add_event = make_dummy_device_event(true, device_name, capabilities)

	local valid_cap_sub = conn:subscribe(capability_event_path(1))
	local invalid_cap_sub = conn:subscribe(capability_event_path(2))

	-- Publish device add event with one valid and one invalid capability
	hal.device_event_q:put(device_add_event)

	-- The valid capability should still produce an event
	local expected_valid_event = make_expected_capability_event(device_name, 1, true)
	expect_capability_event(valid_cap_sub, ctx, expected_valid_event, "for valid capability1")

	-- The invalid capability (missing id) should not produce any event
	assert_no_capability_event(ctx, invalid_cap_sub, " for invalid capability2 (missing id)")

	ctx:cancel("test complete")
end

function TestHalDeviceCapabilityEvent:test_device_capability_duplicate_id_event()
	local hal, ctx, bus, conn, new_msg = new_hal_env()
	hal:start(ctx, bus:connect())
	local device_name1 = 'dummy_dup_cap_device1'
	local device_name2 = 'dummy_dup_cap_device2'
	local capabilities1 = make_dummy_capability_list(1)
	local capabilities2 = make_dummy_capability_list(1)
	local device1_add_event = make_dummy_device_event(true, device_name1, capabilities1)
	local device2_add_event = make_dummy_device_event(true, device_name2, capabilities2)
	local cap_sub = conn:subscribe(capability_event_path(1))

	-- Publish two add events with the same capability id; HAL should handle
	-- the duplicate id by overwriting the existing entry and still publishing
	-- capability events for both devices.
	hal.device_event_q:put(device1_add_event)
	hal.device_event_q:put(device2_add_event)

	local expected_event1 = make_expected_capability_event(device_name1, 1, true)
	expect_capability_event(cap_sub, ctx, expected_event1, "for capability1 first add")

	local expected_event2 = make_expected_capability_event(device_name2, 1, true)
	expect_capability_event(cap_sub, ctx, expected_event2, "for capability1 second add (duplicate id)")

	ctx:cancel("test complete")
end

function TestHalDeviceCapabilityEvent:test_add_remove_add_capability_event()
	local hal, ctx, bus, conn, new_msg = new_hal_env()
	hal:start(ctx, bus:connect())
	local device_name = 'dummy_add_remove_add_device'
	local capabilities = make_dummy_capability_list(1)
	local device_add_event = make_dummy_device_event(true, device_name, capabilities)
	local device_remove_event = make_dummy_device_event(false, device_name, nil)

	local cap_sub = conn:subscribe(capability_event_path(1))

	-- 1. Add event
	hal.device_event_q:put(device_add_event)

	local expected_add_event = make_expected_capability_event(device_name, 1, true)
	expect_capability_event(cap_sub, ctx, expected_add_event, "for capability1 add")

	-- 2. Remove event
	hal.device_event_q:put(device_remove_event)

	-- A nil payload is sent first to remove retained values under the topic
	expect_retained_drop_event(ctx, cap_sub)

	local expected_remove_event = make_expected_capability_event(device_name, 1, false)
	expect_capability_event(cap_sub, ctx, expected_remove_event, "for capability1 remove")

	-- 3. Add event again
	hal.device_event_q:put(device_add_event)

	expect_capability_event(cap_sub, ctx, expected_add_event, "for capability1 add again")

	ctx:cancel("test complete")
end

function TestHalDeviceCapabilityEvent:test_device_capability_nil_control_event()
	local hal, ctx, bus, conn, new_msg = new_hal_env()
	hal:start(ctx, bus:connect())
	local device_name = 'dummy_nil_control_device'
	local capabilities = make_dummy_capability_list(1)
	-- Invalidate the control field; this capability should be ignored.
	capabilities["capability1"].control = nil
	local device_add_event = make_dummy_device_event(true, device_name, capabilities)
	local cap_sub = conn:subscribe(capability_event_path(1))

	hal.device_event_q:put(device_add_event)

	-- No capability event should be published when control is nil.
	assert_no_capability_event(ctx, cap_sub, " for capability1 with nil control")

	ctx:cancel("test complete")
end

TestHalCapabilityControl = {}

local function capability_control_path(capability_type, capability_index, endpoint)
	return { 'hal', 'capability', capability_type, tostring(capability_index), 'control', endpoint }
end

function TestHalCapabilityControl:test_capability_control_endpoints()
	local hal, ctx, bus, conn, new_msg = new_hal_env()
	hal:start(ctx, bus:connect())
	local capabilities = make_dummy_capability_list(1)
	local device_event = make_dummy_device_event(true, "test_device", capabilities)
	local cap_sub = conn:subscribe(capability_event_path(1))

	hal.device_event_q:put(device_event)

	local expected_event = make_expected_capability_event("test_device", 1, true)
	expect_capability_event(cap_sub, ctx, expected_event, "for capability1 add") -- wait for capability to appear

	-- 1. Test no_args endpoint
	local cap_control_sub = conn:request(new_msg(
		capability_control_path("capability1", 1, "no_args")
	))

	local response, err = harness.wait_for_msg(cap_control_sub, ctx)
	luaunit.assertNil(err, "Expected to receive capability control response")
	local expected_result = wrap_result(1, "no_args_endpoint")
	luaunit.assertEquals(response.payload, expected_result, "Expected capability control response to match")

	-- 2. Test single_arg endpoint
	cap_control_sub = conn:request(new_msg(
		capability_control_path("capability1", 1, "single_arg"),
		{ "arg1_value" }
	))
	response, err = harness.wait_for_msg(cap_control_sub, ctx)
	luaunit.assertNil(err, "Expected to receive capability control response")
	expected_result = wrap_result(1, "single_arg_endpoint", { "arg1_value" }, 1)
	luaunit.assertEquals(response.payload, expected_result, "Expected capability control response to match")

	-- 3. Test multi_arg endpoint
	cap_control_sub = conn:request(new_msg(
		capability_control_path("capability1", 1, "multi_arg"),
		{ "arg1", "arg2", "arg3" }
	))
	response, err = harness.wait_for_msg(cap_control_sub, ctx)
	luaunit.assertNil(err, "Expected to receive capability control response")
	expected_result = wrap_result(1, "multi_arg_endpoint", { "arg1", "arg2", "arg3" }, 3)
	luaunit.assertEquals(response.payload, expected_result, "Expected capability control response to match")

	-- 4. Test error_fn endpoint
	cap_control_sub = conn:request(new_msg(
		capability_control_path("capability1", 1, "error_fn")
	))
	response, err = harness.wait_for_msg(cap_control_sub, ctx)
	luaunit.assertNil(err, "Expected to receive capability control response")
	expected_result = wrap_error("Capability function error")
	luaunit.assertEquals(response.payload, expected_result, "Expected capability control response to match")

	ctx:cancel("test complete")
end

function TestHalCapabilityControl:test_invalid_capability_control_endpoints()
	local hal, ctx, bus, conn, new_msg = new_hal_env()
	hal:start(ctx, bus:connect())
	local capabilities = make_dummy_capability_list(1)
	local device_event = make_dummy_device_event(true, "test_device_invalid_control", capabilities)
	local cap_sub = conn:subscribe(capability_event_path(1))

	hal.device_event_q:put(device_event)

	local expected_event = make_expected_capability_event("test_device_invalid_control", 1, true)
	expect_capability_event(cap_sub, ctx, expected_event, "for capability1 add") -- wait for capability to appear

	-- 1. Non-existent function
	local cap_control_sub = conn:request(new_msg(
		capability_control_path("capability1", 1, "invalid_endpoint")
	))

	local response, err = harness.wait_for_msg(cap_control_sub, ctx)
	luaunit.assertNil(err, "Expected to receive capability control response")
	local expected_result = wrap_error('endpoint does not exist')
	luaunit.assertEquals(response.payload, expected_result, "Expected capability control response to match")

	-- 2. Non-existent capability index
	cap_control_sub = conn:request(new_msg(
		capability_control_path("capability1", 999, "no_args")
	))

	response, err = harness.wait_for_msg(cap_control_sub, ctx)
	luaunit.assertNil(err, "Expected to receive capability control response")
	expected_result = wrap_error('capability instance does not exist')
	luaunit.assertEquals(response.payload, expected_result, "Expected capability control response to match")

	-- 3. Non-existent capability type
	cap_control_sub = conn:request(new_msg(
		capability_control_path("invalid_capability", 1, "no_args")
	))
	response, err = harness.wait_for_msg(cap_control_sub, ctx)
	luaunit.assertNil(err, "Expected to receive capability control response")
	expected_result = wrap_error('capability does not exist')
	luaunit.assertEquals(response.payload, expected_result, "Expected capability control response to match")
	ctx:cancel("test complete")
end

function TestHalCapabilityControl:test_no_endpoint_on_removal()
	local hal, ctx, bus, conn, new_msg = new_hal_env()
	hal:start(ctx, bus:connect())
	local device_name = 'dummy_control_remove_device'
	local capabilities = make_dummy_capability_list(1)
	local device_add_event = make_dummy_device_event(true, device_name, capabilities)
	local device_remove_event = make_dummy_device_event(false, device_name, nil)

	local cap_sub = conn:subscribe(capability_event_path(1))

	-- 1. Add event
	hal.device_event_q:put(device_add_event)

	local expected_add_event = make_expected_capability_event(device_name, 1, true)
	expect_capability_event(cap_sub, ctx, expected_add_event, "for capability1 add")

	-- 2. Remove event
	hal.device_event_q:put(device_remove_event)

	-- A nil payload is sent first to remove retained values under the topic
	expect_retained_drop_event(ctx, cap_sub)

	local expected_remove_event = make_expected_capability_event(device_name, 1, false)
	expect_capability_event(cap_sub, ctx, expected_remove_event, "for capability1 remove")

	-- Now try to call an endpoint on the removed capability
	local cap_control_sub = conn:request(new_msg(
		capability_control_path("capability1", 1, "no_args")
	))

	local response, err = harness.wait_for_msg(cap_control_sub, ctx)
	luaunit.assertNil(err, "Expected to receive capability control response")
	local expected_result = wrap_error('capability instance does not exist')
	luaunit.assertEquals(response.payload, expected_result, "Expected capability control response to match")

	ctx:cancel("test complete")
end

function TestHalCapabilityControl:test_publish_control()
	local hal, ctx, bus, conn, new_msg = new_hal_env()
	local channel = require 'fibers.channel'
	local ch = channel.new()
	hal:start(ctx, bus:connect())
	local capabilities = make_dummy_capability_list(1)
	-- New endpoint to detect run of endpoint
	capabilities["capability1"].control["trigger_channel"] = function(_, args)
		ch:put(args[1])
		return wrap_result("") -- we won't receive this
	end
	local device_event = make_dummy_device_event(true, "test_device_publish_control", capabilities)
	local cap_sub = conn:subscribe(capability_event_path(1))

	hal.device_event_q:put(device_event)

	local expected_event = make_expected_capability_event("test_device_publish_control", 1, true)
	expect_capability_event(cap_sub, ctx, expected_event, "for capability1 add") -- wait for capability to appear

	-- Now publish a control message directly to the capability control topic
	conn:publish(new_msg(
		capability_control_path("capability1", 1, "trigger_channel"),
		{ 42 }
	))
	-- Wait for the channel to be triggered using cooperative waiting
	local received
	fiber.spawn(function()
		received = ch:get()
	end)
	local ok, reason = harness.wait_until(ctx, function()
		return received ~= nil
	end)
	luaunit.assertTrue(ok,
		"Expected capability control endpoint to trigger channel, but wait_until failed: " .. tostring(reason))
	luaunit.assertEquals(received, 42, "Expected capability control endpoint to trigger channel with argument")
end

TestHalCapabilityInfo = {}

local function capability_info_path(type, id, endpoints)
	if endpoints == nil then endpoints = {} end
    return { 'hal', 'capability', type, id, 'info', unpack(endpoints) }
end

function TestHalCapabilityInfo:test_simple_info()
	local hal, ctx, bus, conn, new_msg = new_hal_env()
	hal:start(ctx, bus:connect())
	local info_q = hal.capability_info_q
	local info_sub = conn:subscribe(capability_info_path("dummy", "1"))

	local info = "test"
	info_q:put({
		type = "dummy",
		id = "1",
		sub_topic = {},
		endpoints = "single",
		info = info,
	})

	local msg, err = harness.wait_for_msg(info_sub, ctx)
	luaunit.assertNil(err, "Expected to receive capability info message")
	luaunit.assertNotNil(msg, "Expected to receive capability info message")
	luaunit.assertEquals(msg.payload, info, "Expected capability info payload to match")
	ctx:cancel("test complete")
end

function TestHalCapabilityInfo:test_tabled_info()
	local hal, ctx, bus, conn, new_msg = new_hal_env()
	hal:start(ctx, bus:connect())
	local info_q = hal.capability_info_q
	local info_sub = conn:subscribe(capability_info_path("dummy", "2"))
	local no_info_sub_1 = conn:subscribe(capability_info_path("dummy", "2", { "field1" }))
	local no_info_sub_2 = conn:subscribe(capability_info_path("dummy", "2", { "field2" }))

	local info = {
		field1 = "value1",
		field2 = 42,
	}
	info_q:put({
		type = "dummy",
		id = "2",
		sub_topic = {},
		endpoints = "single",
		info = info,
	})

	local msg, err = harness.wait_for_msg(info_sub, ctx)
	luaunit.assertNil(err, "Expected to receive capability info message")
	luaunit.assertNotNil(msg, "Expected to receive capability info message")
	luaunit.assertEquals(msg.payload, info, "Expected capability info payload to match")

	local msg2, err2 = harness.wait_for_msg(no_info_sub_1, ctx)
	luaunit.assertNil(msg2, "Expected to not receive capability info message with subtopic")
	luaunit.assertEquals(err2, 'timeout',
		"Expected timeout with subtopic for missing capability info, got: " .. tostring(err2))

	local msg3, err3 = harness.wait_for_msg(no_info_sub_2, ctx)
	luaunit.assertNil(msg3, "Expected to not receive capability info message with subtopic")
	luaunit.assertEquals(err3, 'timeout',
		"Expected timeout with subtopic for missing capability info, got: " .. tostring(err3))

	ctx:cancel("test complete")
end

function TestHalCapabilityInfo:test_info_with_subtopic()
	local hal, ctx, bus, conn, new_msg = new_hal_env()
	hal:start(ctx, bus:connect())
	local info_q = hal.capability_info_q
	local info_sub = conn:subscribe(capability_info_path("dummy", "3", { "subtopic1", "subtopic2" }))

	local info = "subtopic_info"
	info_q:put({
		type = "dummy",
		id = "3",
		sub_topic = { "subtopic1", "subtopic2" },
		endpoints = "single",
		info = info,
	})

	local msg, err = harness.wait_for_msg(info_sub, ctx)
	luaunit.assertNil(err, "Expected to receive capability info message")
	luaunit.assertNotNil(msg, "Expected to receive capability info message")
	luaunit.assertEquals(msg.payload, info, "Expected capability info payload to match")
	ctx:cancel("test complete")
end

function TestHalCapabilityInfo:test_tabled_info_publish_multiple()
	local hal, ctx, bus, conn, new_msg = new_hal_env()
	hal:start(ctx, bus:connect())
	local info_q = hal.capability_info_q
	local info_sub_1 = conn:subscribe(capability_info_path("dummy", "3", { "field1" }))
	local info_sub_2 = conn:subscribe(capability_info_path("dummy", "3", { "field2" }))
	local no_info_sub = conn:subscribe(capability_info_path("dummy", "3"))

	local info = {
		field1 = "value1",
		field2 = 42,
	}
	info_q:put({
		type = "dummy",
		id = "3",
		endpoints = "multiple",
		info = info,
	})

	local msg, err = harness.wait_for_msg(info_sub_1, ctx)
	luaunit.assertNil(err, "Expected to receive capability info message")
	luaunit.assertNotNil(msg, "Expected to receive capability info message")
	luaunit.assertEquals(msg.payload, info.field1, "Expected capability info payload to match")

	local msg2, err2 = harness.wait_for_msg(info_sub_2, ctx)
	luaunit.assertNil(err2, "Expected to receive capability info message")
	luaunit.assertNotNil(msg2, "Expected to receive capability info message")
	luaunit.assertEquals(msg2.payload, info.field2, "Expected capability info payload to match")

	local msg3, err3 = harness.wait_for_msg(no_info_sub, ctx)
	luaunit.assertNil(msg3, "Expected to not receive capability info message without subtopic")
	luaunit.assertEquals(err3, 'timeout',
		"Expected timeout without subtopic for missing capability info, got: " .. tostring(err3))

	ctx:cancel("test complete")
end

function TestHalCapabilityInfo:test_info_invalid()
	local hal, ctx, bus, conn, new_msg = new_hal_env()
	hal:start(ctx, bus:connect())
	local info_q = hal.capability_info_q
	local info_sub = conn:subscribe(capability_info_path("dummy", "4"))

	-- Missing type
	info_q:put({
		id = "4",
		sub_topic = {},
		endpoints = "single",
		info = "invalid_info",
	})

	local msg, err = harness.wait_for_msg(info_sub, ctx)
	luaunit.assertNil(msg, "Expected to not receive capability info message with missing type")
	luaunit.assertEquals(err, 'timeout',
		"Expected timeout with missing type for capability info, got: " .. tostring(err))

	-- Missing id
	info_q:put({
		type = "dummy",
		sub_topic = {},
		endpoints = "single",
		info = "invalid_info",
	})

	msg, err = harness.wait_for_msg(info_sub, ctx)
	luaunit.assertNil(msg, "Expected to not receive capability info message with missing id")
	luaunit.assertEquals(err, 'timeout',
		"Expected timeout with missing id for capability info, got: " .. tostring(err))

	-- Missing endpoints
	info_q:put({
		type = "dummy",
		id = "4",
		sub_topic = {},
		info = "invalid_info",
	})

	msg, err = harness.wait_for_msg(info_sub, ctx)
	luaunit.assertNil(msg, "Expected to not receive capability info message with missing endpoints")
	luaunit.assertEquals(err, 'timeout',
		"Expected timeout with missing endpoints for capability info, got: " .. tostring(err))

	ctx:cancel("test complete")
end

local function main()
	fiber.spawn(function()
		luaunit.LuaUnit.run()
		fiber.stop()
	end)
end

-- Only run tests if this file is executed directly (not via dofile)
if is_entry_point then
	main()
	fiber.main()
end
