local luaunit = require 'luaunit'
local timed_cache = require 'services.metrics.timed_cache'
local processing = require 'services.metrics.processing'
local action_cache = require 'services.metrics.action_cache'
local metrics = require 'services.metrics'
local sc = require "fibers.utils.syscall"
local sleep = require "fibers.sleep"
local fiber = require "fibers.fiber"

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

fiber.spawn(function ()
    luaunit.LuaUnit.run()
    fiber.stop()
end)

fiber.main()
