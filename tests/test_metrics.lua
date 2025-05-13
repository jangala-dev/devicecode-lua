local luaunit = require 'luaunit'
local timed_cache = require 'services.metrics.timed_cache'
local processing = require 'services.metrics.processing'
local action_cache = require 'services.metrics.action_cache'
local metrics = require 'services.metrics'
local sc = require "fibers.utils.syscall"
local sleep = require "fibers.sleep"
local fiber = require "fibers.fiber"
local senml = require "services.metrics.senml"

TestTimedCache = {}

function TestTimedCache:test_new_cache()
    local cache = timed_cache.new(1, sc.monotime)
    luaunit.assertNotNil(cache)
    local current_time = sc.monotime()
    luaunit.assertEquals(cache.period, 1)
    luaunit.assertAlmostEquals(cache.next_deadline, current_time + 1, 0.1)
end

function TestTimedCache:test_set_and_get()
    local cache = timed_cache.new(1, sc.monotime)
    local current_time = sc.monotime()
    cache:set("test", 123)
    cache:set({"nested", "key"}, 456)

    local result = cache:get_op():perform()
    luaunit.assertEquals(result.test, 123)
    luaunit.assertEquals(result.nested.key, 456)
    luaunit.assertAlmostEquals(cache.next_deadline, current_time + 2, 0.1)
end

function TestTimedCache:test_nested_key_insertion_order1()
    local cache = timed_cache.new(1, sc.monotime)
    cache:set({ "metrics", "system", "memory" }, "8GB")
    cache:set({ "metrics", "system" }, "active")

    -- Verify the exact structure of the store
    luaunit.assertEquals(cache.store.metrics.system.__value, "active")
    luaunit.assertEquals(cache.store.metrics.system.memory, "8GB")
end

function TestTimedCache:test_nested_key_insertion_order2()
    local cache = timed_cache.new(1, sc.monotime)
    cache:set({ "metrics", "system" }, "active")
    cache:set({ "metrics", "system", "memory" }, "8GB")

    -- Verify the exact structure of the store
    luaunit.assertEquals(cache.store.metrics.system.__value, "active")
    luaunit.assertEquals(cache.store.metrics.system.memory, "8GB")
end
TestProcessing = {}

function TestProcessing:test_diff_trigger()
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

function TestProcessing:test_time_trigger()
    local config = { duration = 1 }
    local trigger = processing.TimeTrigger.new(config)

    local val, short, err = trigger:run(123)
    luaunit.assertNil(err)
    luaunit.assertEquals(short, true) -- Should short circuit initially

    sleep.sleep(2)
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
    local pipeline = processing.new_process_pipeline({})

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
TestActionCache = {}

function TestActionCache:test_set_and_update()
    local cache = action_cache.new()
    local process = processing.DiffTrigger.new({
        threshold = 5,
        diff_method = "absolute"
    })

    local val, short = cache:set("test", 10, process)
    luaunit.assertEquals(val, 10)
    luaunit.assertEquals(short, false)

    val, short = cache:update("test", 12)
    luaunit.assertEquals(short, true) -- Should short circuit as diff < threshold

    val, short = cache:update("test", 16)
    luaunit.assertEquals(short, false) -- Should pass as diff >= threshold
    luaunit.assertEquals(val, 16)
end

function TestActionCache:test_nested_values()
    local cache = action_cache.new()
    local process = processing.DiffTrigger.new({
        threshold = 5,
        diff_method = "absolute"
    })

    -- Test nested structure
    local val, short = cache:set({ "system", "resources" }, {
        cpu = 80,
        memory = 50
    }, process)

    luaunit.assertEquals(val.cpu, 80)
    luaunit.assertEquals(val.memory, 50)
    luaunit.assertEquals(short, false)

    -- Update with small changes (should short circuit)
    val, short = cache:update({ "system", "resources" }, {
        cpu = 82,
        memory = 52
    })
    luaunit.assertEquals(short, true)

    -- Update with large changes (should pass through)
    val, short = cache:update({ "system", "resources" }, {
        cpu = 90,
        memory = 60
    })
    luaunit.assertEquals(short, false)
    luaunit.assertEquals(val.cpu, 90)
    luaunit.assertEquals(val.memory, 60)
end

function TestActionCache:test_invalid_updates()
    local cache = action_cache.new()

    -- Try to update non-existent key
    local val, short, err = cache:update("nonexistent", 123)
    luaunit.assertEquals(short, true)
    luaunit.assertNotNil(err)

    -- Try to set invalid process
    local val2, short2, err2 = cache:set("test", 123, nil)
    luaunit.assertNotNil(err2)
end
TestMetricsService = {}

function TestMetricsService:test_build_metric_pipeline()
    local process_config = {
        {
            type = "DiffTrigger",
            threshold = 5,
            diff_method = "absolute"
        },
        {
            type = "TimeTrigger",
            duration = 10
        }
    }

    local pipeline, err = metrics:_build_metric_pipeline("test/endpoint", process_config)
    luaunit.assertNil(err)
    luaunit.assertNotNil(pipeline)
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
fiber.spawn(function ()
    luaunit.LuaUnit.run()
    fiber.stop()
end)

fiber.main()
