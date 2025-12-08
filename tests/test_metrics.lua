-- Detect if this file is being run as the entry point
local this_file = debug.getinfo(1, "S").source:match("@?([^/]+)$")
local is_entry_point = arg and arg[0] and arg[0]:match("[^/]+$") == this_file

if is_entry_point then
    package.path = "../src/lua-fibers/?.lua;" -- fibers submodule src
        .. "../src/lua-trie/src/?.lua;"       -- trie submodule src
        .. "../src/lua-bus/src/?.lua;"        -- bus submodule src
        .. "../src/?.lua;"
        .. "./test_utils/?.lua;"
        .. package.path
        .. ";/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua"

    _G._TEST = true -- Enable test exports in source code
end

local luaunit = require 'luaunit'
local processing = require 'services.metrics.processing'
local conf = require 'services.metrics.config'
local sc = require "fibers.utils.syscall"
local sleep = require "fibers.sleep"
local fiber = require "fibers.fiber"
local senml = require "services.metrics.senml"

TestProcessing = {}

function TestProcessing:test_diff_trigger_absolute()
    local config = {
        threshold = 5,
        diff_method = "absolute",
        initial_val = 10
    }

    local trigger, trig_err = processing.DiffTrigger.new(config)
    luaunit.assertNil(trig_err)
    local val, short, err = trigger:run(12)
    luaunit.assertNil(err)
    luaunit.assertEquals(short, true) -- Should short circuit as diff < threshold

    val, short, err = trigger:run(16)
    luaunit.assertNil(err)
    luaunit.assertEquals(short, false) -- Should pass as diff >= threshold
    luaunit.assertEquals(val, 16)
end

function TestProcessing:test_diff_trigger_percent()
    local config = {
        threshold = 10, -- 10% threshold
        diff_method = "percent",
        initial_val = 100
    }

    local trigger, trig_err = processing.DiffTrigger.new(config)
    luaunit.assertNil(trig_err)

    -- 5% change - should short circuit
    local val, short, err = trigger:run(105)
    luaunit.assertNil(err)
    luaunit.assertEquals(short, true)

    -- 15% change - should pass
    val, short, err = trigger:run(115)
    luaunit.assertNil(err)
    luaunit.assertEquals(short, false)
    luaunit.assertEquals(val, 115)
end

function TestProcessing:test_diff_trigger_any_change()
    local config = {
        diff_method = "any-change",
        initial_val = 10
    }

    local trigger, trig_err = processing.DiffTrigger.new(config)
    luaunit.assertNil(trig_err)

    -- Same value - should short circuit
    local val, short, err = trigger:run(10)
    luaunit.assertNil(err)
    luaunit.assertEquals(short, true)

    -- Any change - should pass
    val, short, err = trigger:run(10.1)
    luaunit.assertNil(err)
    luaunit.assertEquals(short, false)
    luaunit.assertEquals(val, 10.1)
end

function TestProcessing:test_time_trigger()
    local config = { duration = 0.1 }
    local trigger = processing.TimeTrigger.new(config)

    local val, short, err = trigger:run(123)
    luaunit.assertNil(err)
    luaunit.assertEquals(short, true) -- Should short circuit initially

    sleep.sleep(0.2)
    val, short, err = trigger:run(123)
    luaunit.assertNil(err)
    luaunit.assertEquals(short, false) -- Should pass after duration
    luaunit.assertEquals(val, 123)
end

function TestProcessing:test_delta_value()
    local delta = processing.DeltaValue.new({ initial_val = 10 })

    local val, short, err = delta:run(15)
    luaunit.assertNil(err)
    luaunit.assertEquals(short, false)
    luaunit.assertEquals(val, 5) -- Should return difference

    delta:reset()
    val, short, err = delta:run(20)
    luaunit.assertNil(err)
    luaunit.assertEquals(short, false)
    luaunit.assertEquals(val, 5)
end

function TestProcessing:test_clone_process()
    local config = {
        threshold = 5,
        diff_method = "absolute",
        initial_val = 10
    }

    local trigger, trig_err = processing.DiffTrigger.new(config)
    luaunit.assertNil(trig_err)

    local clone, clone_err = trigger:clone()
    luaunit.assertNil(clone_err)
    luaunit.assertNotNil(clone)

    -- Test that clone behaves the same as original
    local val1, short1, err1 = trigger:run(16)
    local val2, short2, err2 = clone:run(16)

    luaunit.assertEquals(val1, val2)
    luaunit.assertEquals(short1, short2)
    luaunit.assertEquals(err1, err2)
end

function TestProcessing:test_process_pipeline()
    local pipeline = processing.new_process_pipeline()

    -- Create a pipeline with DiffTrigger and DeltaValue
    local diff_trigger = processing.DiffTrigger.new({
        threshold = 5,
        diff_method = "absolute",
        initial_val = 10
    })
    local delta_value = processing.DeltaValue.new({ initial_val = 10 })

    pipeline:add(diff_trigger)
    pipeline:add(delta_value)

    -- First run should pass through both processes
    local val, short, err = pipeline:run(20)
    luaunit.assertNil(err)
    luaunit.assertEquals(short, false)
    luaunit.assertEquals(val, 10) -- DeltaValue should return difference from initial

    -- Second run should short circuit at DiffTrigger
    val, short, err = pipeline:run(22)
    luaunit.assertNil(err)
    luaunit.assertEquals(short, true)
end

function TestProcessing:test_pipeline_reset()
    local pipeline = processing.new_process_pipeline()
    local delta_value = processing.DeltaValue.new({ initial_val = 10 })
    pipeline:add(delta_value)

    -- Run once to get delta
    local val, short, err = pipeline:run(20)
    luaunit.assertNil(err)
    luaunit.assertEquals(val, 10)

    -- Reset pipeline
    pipeline:reset()

    -- Next run should use the last value as new base
    val, short, err = pipeline:run(25)
    luaunit.assertNil(err)
    luaunit.assertEquals(val, 5) -- 25 - 20
end

TestConfig = {}

function TestConfig:test_build_metric_pipeline_via_apply_config()
    -- Test pipeline building indirectly through apply_config
    -- which is the main way pipelines are created
    local mock_conn = {
        subscribe = function(self, topic)
            return {
                next_msg_op = function() end,
                unsubscribe = function() end
            }
        end
    }

    local config = {
        templates = {},
        collections = {
            ["test/endpoint"] = {
                protocol = "log",
                process = {
                    {
                        type = "DiffTrigger",
                        threshold = 5,
                        diff_method = "absolute"
                    }
                }
            }
        },
        publish_period = 60
    }

    local metrics, period, cloud_config = conf.apply_config(mock_conn, config, {})
    luaunit.assertEquals(#metrics, 1)
    luaunit.assertEquals(period, 60)
    luaunit.assertNotNil(metrics[1].base_pipeline)
end

function TestConfig:test_validate_http_config()
    -- Valid config
    local valid_config = {
        url = "http://example.com",
        thing_key = "test_key",
        channels = {
            { id = "ch1", name = "data", metadata = { channel_type = "data" } }
        }
    }
    local valid, err = conf.validate_http_config(valid_config)
    luaunit.assertTrue(valid)
    luaunit.assertNil(err)

    -- Missing url
    local invalid_config = {
        thing_key = "test_key",
        channels = {}
    }
    valid, err = conf.validate_http_config(invalid_config)
    luaunit.assertFalse(valid)
    luaunit.assertNotNil(err)

    -- Nil config
    valid, err = conf.validate_http_config(nil)
    luaunit.assertFalse(valid)
    luaunit.assertNotNil(err)
end

function TestConfig:test_merge_config()
    local base = {
        url = "http://base.com",
        thing_key = "base_key",
        nested = {
            field1 = "value1",
            field2 = "value2"
        }
    }

    local override = {
        thing_key = "override_key",
        nested = {
            field2 = "override_value2",
            field3 = "value3"
        }
    }

    local merged = conf.merge_config(base, override)
    luaunit.assertEquals(merged.url, "http://base.com")
    luaunit.assertEquals(merged.thing_key, "override_key")
    luaunit.assertEquals(merged.nested.field1, "value1")
    luaunit.assertEquals(merged.nested.field2, "override_value2")
    luaunit.assertEquals(merged.nested.field3, "value3")
end

function TestConfig:test_validate_topic_with_nil()
    -- Test the actual metrics service validate_topic logic by directly calling _handle_metric
    local metrics_service = require 'services.metrics'
    local bus_pkg = require 'bus'
    local context = require "fibers.context"

    -- Create a bus and connection (but don't start the service)
    local test_bus = bus_pkg.new()
    local conn = test_bus:connect()

    -- Create a context for the metrics service (needed for logging)
    local bg_ctx = context.background()
    local service_ctx = context.with_value(bg_ctx, "service_name", "metrics_test")
    service_ctx = context.with_value(service_ctx, "fiber_name", "test_fiber")

    -- Set up metrics service state manually without starting it
    metrics_service.ctx = service_ctx
    metrics_service.metric_values = {}
    metrics_service.pipelines = {}

    -- Create a pipeline for a test metric
    local base_pipeline = processing.new_process_pipeline()
    local diff_trigger = processing.DiffTrigger.new({
        threshold = 5,
        diff_method = "absolute",
        initial_val = 10
    })
    base_pipeline:add(diff_trigger)

    -- Create a metric definition
    local metric = {
        protocol = "log",
        field = nil,
        rename = nil,
        base_pipeline = base_pipeline
    }

    -- Test 1: Valid topic should work and add value to metric_values
    local valid_msg = bus_pkg.new_msg({"test", "metric"}, 100)
    metrics_service:_handle_metric(metric, valid_msg)
    luaunit.assertNotNil(metrics_service.metric_values.log)
    luaunit.assertNotNil(metrics_service.metric_values.log["test.metric"])
    luaunit.assertEquals(metrics_service.metric_values.log["test.metric"].value, 100)

    -- Reset for next test
    metrics_service.metric_values = {}

    -- Test 2: Invalid topic with nil in the middle should be rejected (not added)
    local invalid_msg_nil = bus_pkg.new_msg({"test", nil, "metric"}, 200)
    metrics_service:_handle_metric(metric, invalid_msg_nil)
    -- Should not create any metric values because topic is invalid
    luaunit.assertTrue((not metrics_service.metric_values.log) or (not metrics_service.metric_values.log["test..metric"]))

    -- Test 3: Invalid topic with gap (sparse array) should be rejected
    local sparse_topic = {}
    sparse_topic[1] = "test"
    sparse_topic[3] = "metric"  -- index 2 is missing
    local sparse_msg = bus_pkg.new_msg(sparse_topic, 300)
    metrics_service:_handle_metric(metric, sparse_msg)
    -- Should not create any metric values because topic is invalid
    luaunit.assertTrue((not metrics_service.metric_values.log) or (not metrics_service.metric_values.log["test.metric"]))

    -- Test 4: Another valid topic should work
    metrics_service.metric_values = {}
    local valid_msg2 = bus_pkg.new_msg({"another", "valid", "topic"}, 50)
    metrics_service:_handle_metric(metric, valid_msg2)
    luaunit.assertNotNil(metrics_service.metric_values.log)
    luaunit.assertNotNil(metrics_service.metric_values.log["another.valid.topic"])

    -- Test 5: Empty topic should be rejected
    metrics_service.metric_values = {}
    local empty_msg = bus_pkg.new_msg({}, 400)
    metrics_service:_handle_metric(metric, empty_msg)
    luaunit.assertNil(metrics_service.metric_values.log)

    -- Clean up
    conn:disconnect()
end

TestSenML = {}

function TestSenML:test_encode_basic()
    -- Test encoding a string
    local result, err = senml.encode("test/topic", "string_value")
    luaunit.assertNil(err)
    luaunit.assertEquals(result.n, "test/topic")
    luaunit.assertEquals(result.vs, "string_value")

    -- Test encoding a number
    result, err = senml.encode("test/topic", 42.5)
    luaunit.assertNil(err)
    luaunit.assertEquals(result.n, "test/topic")
    luaunit.assertEquals(result.v, 42.5)

    -- Test encoding a boolean
    result, err = senml.encode("test/topic", true)
    luaunit.assertNil(err)
    luaunit.assertEquals(result.n, "test/topic")
    luaunit.assertEquals(result.vb, true)

    -- Test encoding with timestamp
    result, err = senml.encode("test/topic", 42, 1234567890)
    luaunit.assertNil(err)
    luaunit.assertEquals(result.t, 1234567890)
end

function TestSenML:test_encode_invalid_types()
    -- Test encoding with invalid type
    local result, err = senml.encode("test/topic", {})
    luaunit.assertNotNil(err)
    luaunit.assertNil(result)

    -- Test encoding with nil
    result, err = senml.encode("test/topic", nil)
    luaunit.assertNotNil(err)
    luaunit.assertNil(result)
end

function TestSenML:test_encode_r_flat()
    -- Test encoding a flat table
    local values = {
        temperature = 23.5,
        humidity = 60,
        status = "online"
    }

    local result, err = senml.encode_r("device/sensors", values)
    luaunit.assertNil(err)
    luaunit.assertEquals(#result, 3)

    -- Check each entry
    local found = { temp = false, humid = false, status = false }
    for _, entry in ipairs(result) do
        if entry.n == "device/sensors.temperature" and entry.v == 23.5 then
            found.temp = true
        elseif entry.n == "device/sensors.humidity" and entry.v == 60 then
            found.humid = true
        elseif entry.n == "device/sensors.status" and entry.vs == "online" then
            found.status = true
        end
    end

    luaunit.assertTrue(found.temp)
    luaunit.assertTrue(found.humid)
    luaunit.assertTrue(found.status)
end

function TestSenML:test_encode_r_nested()
    -- Test encoding a nested table
    local values = {
        system = {
            memory = 8192,
            cpu = 45.6
        },
        network = {
            status = "connected",
            speed = 100
        }
    }

    local result, err = senml.encode_r("device", values)
    luaunit.assertNil(err)
    luaunit.assertEquals(#result, 4)

    -- Check specific entries
    local found = { memory = false, cpu = false, net_status = false, speed = false }
    for _, entry in ipairs(result) do
        if entry.n == "device.system.memory" and entry.v == 8192 then
            found.memory = true
        elseif entry.n == "device.system.cpu" and entry.v == 45.6 then
            found.cpu = true
        elseif entry.n == "device.network.status" and entry.vs == "connected" then
            found.net_status = true
        elseif entry.n == "device.network.speed" and entry.v == 100 then
            found.speed = true
        end
    end

    luaunit.assertTrue(found.memory)
    luaunit.assertTrue(found.cpu)
    luaunit.assertTrue(found.net_status)
    luaunit.assertTrue(found.speed)
end

function TestSenML:test_encode_r_with_value_field()
    -- Test encoding a table with __value field and a subtable
    local values = {
        system = {
            __value = "active", -- This should be at the base topic
            memory = {
                __value = "healthy",
                used = 4096,
                free = 4096
            }
        }
    }

    local result, err = senml.encode_r("device", values)
    luaunit.assertNil(err)

    -- Check for all expected entries
    local found = { system = false, memory = false, used = false, free = false }
    for _, entry in ipairs(result) do
        if entry.n == "device.system" and entry.vs == "active" then
            found.system = true
        elseif entry.n == "device.system.memory" and entry.vs == "healthy" then
            found.memory = true
        elseif entry.n == "device.system.memory.used" and entry.v == 4096 then
            found.used = true
        elseif entry.n == "device.system.memory.free" and entry.v == 4096 then
            found.free = true
        end
    end

    luaunit.assertTrue(found.system)
    luaunit.assertTrue(found.memory)
    luaunit.assertTrue(found.used)
    luaunit.assertTrue(found.free)
    luaunit.assertEquals(#result, 4)
end

function TestSenML:test_encode_r_with_value_and_time()
    -- Test encoding values with explicit value and time fields
    local values = {
        temperature = {
            value = 23.5,
            time = 1234567890
        },
        status = "online"
    }

    local result, err = senml.encode_r("sensor", values)
    luaunit.assertNil(err)
    luaunit.assertEquals(#result, 2)

    -- Check entries
    local found = { temp = false, status = false }
    for _, entry in ipairs(result) do
        if entry.n == "sensor.temperature" and entry.v == 23.5 and entry.t == 1234567890 then
            found.temp = true
        elseif entry.n == "sensor.status" and entry.vs == "online" then
            found.status = true
        end
    end

    luaunit.assertTrue(found.temp)
    luaunit.assertTrue(found.status)
end

-- Only run tests if this file is executed directly (not via dofile)
if is_entry_point then
    fiber.spawn(function ()
        luaunit.LuaUnit.run()
        fiber.stop()
    end)

    fiber.main()
end
