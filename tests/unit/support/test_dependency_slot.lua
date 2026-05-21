local fibers = require 'fibers'
local busmod = require 'bus'
local runfibers = require 'tests.support.run_fibers'
local slot = require 'devicecode.support.dependency_slot'

local T = {}

local function assert_eq(a, b)
	if a ~= b then error('expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end

local function status_topic(class, id)
	return { 'cap', class, id or 'main', 'status' }
end

function T.replace_opens_projects_and_terminates_previous_dependencies()
	runfibers.run(function ()
		local b = busmod.new()
		local conn = b:connect()
		local writer = b:connect()
		local state = {}

		assert(slot.replace(state, 'deps', conn, {
			{ key = 'one', class = 'one', id = 'main' },
		}))
		assert(state.deps ~= nil)
		writer:retain(status_topic('one', 'main'), { state = 'available', available = true })
		local ev = fibers.perform(state.deps:event_source():recv_op())
		assert_eq(ev.key, 'one')
		assert_eq(slot.snapshot(state, 'deps').one.available, true)

		assert(slot.replace(state, 'deps', conn, {
			{ key = 'two', class = 'two', id = 'main' },
		}))
		assert(state.deps ~= nil)
		assert(slot.snapshot(state, 'deps').one == nil)
		writer:retain(status_topic('two', 'main'), { state = 'available', available = true })
		ev = fibers.perform(state.deps:event_source():recv_op())
		assert_eq(ev.key, 'two')

		slot.terminate(state, 'deps', 'test_complete')
		assert(state.deps == nil)
	end)
end

function T.empty_specs_clear_slot_without_opening_manager()
	runfibers.run(function ()
		local state = { deps = { terminate = function (self, reason) self.reason = reason end } }
		local ok, err, deps = slot.replace(state, 'deps', nil, {}, { replace_reason = 'empty' })
		assert_eq(ok, true)
		assert_eq(err, nil)
		assert_eq(deps, nil)
		assert(state.deps == nil)
		local src = slot.event_source(state, 'deps', { name = 'unused' })
		assert_eq(src, nil)
	end)
end

return T
