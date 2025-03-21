local lu = require('luaunit')
local rc = require('reactive_cache')

TestDiffTrigger = {}

function TestDiffTrigger:setUp()
    self.trigger_abs = rc.DiffTrigger.new('absolute', 5, 10) -- 5 threshold starting at 10
    self.trigger_pct = rc.DiffTrigger.new('percent', 10, 100)  -- 10% threshold starting at 100
end

function TestDiffTrigger:test_absolute_trigger()
    lu.assertFalse(self.trigger_abs:is_active())

    self.trigger_abs:update_val(14)  -- diff = 4
    lu.assertFalse(self.trigger_abs:is_active())

    self.trigger_abs:update_val(20)  -- diff = 6
    lu.assertTrue(self.trigger_abs:is_active())
end

function TestDiffTrigger:test_percent_trigger()
    lu.assertFalse(self.trigger_pct:is_active())

    self.trigger_pct:update_val(109)  -- 9% change
    lu.assertFalse(self.trigger_pct:is_active())

    self.trigger_pct:update_val(90)   -- >10% change
    lu.assertTrue(self.trigger_pct:is_active())
end

TestTimeTrigger = {}

function TestTimeTrigger:test_time_trigger()
    local trigger = rc.TimeTrigger.new(1)  -- 1 second timeout
    lu.assertFalse(trigger:is_active())
    os.execute("sleep 2")  -- Wait over 1 second
    lu.assertTrue(trigger:is_active())
end

TestReactiveCache = {}

function TestReactiveCache:setUp()
    self.cache = rc.ReactiveCache.new()
end

function TestReactiveCache:test_basic_operations()
    local trigger = rc.DiffTrigger.new('absolute', 5, 10)
    self.cache:set("test", 10, trigger)

    lu.assertNotNil(self.cache:has_key("test"))
    lu.assertNil(self.cache:get("test"))  -- Should be nil as trigger not active

    local updated = self.cache:update("test", 16)
    lu.assertNotNil(updated)  -- Should return value as trigger is active
    lu.assertEquals(updated, 16)
end

function TestReactiveCache:test_nested_keys()
    local trigger = rc.DiffTrigger.new('absolute', 5, 10)
    self.cache:set("sensor", {
        temp = 20,
        humidity = 50
    }, trigger)

    lu.assertTrue(self.cache:has_key({"sensor", "temp"}))
    lu.assertTrue(self.cache:has_key({"sensor", "humidity"}))

    local updated = self.cache:update({"sensor", "temp"}, 26)
    lu.assertNotNil(updated)
    lu.assertEquals(updated, 26)
end

function TestReactiveCache:test_array_values_any_mode()
    local trigger = rc.ArrayDiffTrigger.new('absolute', {5, 5, 5}, {10, 10, 10}, 'any')
    self.cache:set("array", {10, 20, 30}, trigger)

    lu.assertNotNil(self.cache:has_key("array"))
    local updated = self.cache:update("array", {11, 12, 13})
    lu.assertNil(updated)

    self.cache:update("array", {16, 12, 13})
    local updated, update_err = self.cache:update("array", {16, 12, 13})
    lu.assertNil(update_err)
    lu.assertNotNil(updated)
    lu.assertEquals(updated, {16, 12, 13})
end

function TestReactiveCache:test_array_values_all_mode()
    local trigger = rc.ArrayDiffTrigger.new('absolute', {5, 5, 5}, {10, 10, 10}, 'all')
    self.cache:set("array", {10, 20, 30}, trigger)

    lu.assertNotNil(self.cache:has_key("array"))
    local updated = self.cache:update("array", {11, 12, 13})
    lu.assertNil(updated)

    self.cache:update("array", {16, 12, 13})
    local updated, update_err = self.cache:update("array", {16, 12, 13})
    lu.assertNil(update_err)
    lu.assertNil(updated)


    local updated, update_err = self.cache:update("array", {16, 17, 18})
    lu.assertNil(update_err)
    lu.assertNotNil(updated)
    lu.assertEquals(updated, {16, 17, 18})
end

-- Run the tests
os.exit(lu.LuaUnit.run())
