-- tests/unit/ui/test_sessions.lua

local sessions = require 'services.ui.sessions'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a, b, msg) if a ~= b then fail(msg or ('expected '..tostring(b)..', got '..tostring(a))) end end
local function assert_true(v, msg) if v ~= true then fail(msg or 'expected true') end end
local function assert_nil(v, msg) if v ~= nil then fail(msg or ('expected nil, got '..tostring(v))) end end
local function assert_not_nil(v, msg) if v == nil then fail(msg or 'expected non-nil') end end

function tests.test_create_touch_delete_and_prune_are_immediate()
	local now = 100
	local store = sessions.new({ now = function() return now end, default_ttl = 10 })

	local s = store:create('alice', { id = 's1', data = { role = 'admin' } })
	assert_eq(s.id, 's1')
	assert_eq(s.principal, 'alice')
	assert_eq(store:count(), 1)

	now = 105
	local touched, err = store:touch('s1', { ttl = 20 })
	assert_not_nil(touched, err)
	assert_eq(touched.expires_at, 125)

	assert_true(store:delete('s1'))
	assert_nil(store:get('s1'))

	store:create('bob', { id = 's2', ttl = 1 })
	store:create('carol', { id = 's3', ttl = 100 })
	now = 107
	local removed = store:prune()
	assert_eq(#removed, 1)
	assert_eq(removed[1], 's2')
	assert_eq(store:count(), 1)
end

function tests.test_session_mutations_record_first_class_last_event()
	local now = 100
	local store = sessions.new({
		now = function() return now end,
		default_ttl = 10,
	})

	store:create('alice', { id = 's1' })
	assert_eq(store:last_event().kind, 'session_created')
	assert_eq(store:last_event().session_id, 's1')
	assert_eq(store:last_event().count, 1)

	store:touch('s1')
	assert_eq(store:last_event().kind, 'session_touched')

	store:delete('s1')
	assert_eq(store:last_event().kind, 'session_deleted')
	assert_eq(store:last_event().count, 0)

	store:create('bob', { id = 's2', ttl = 1 })
	assert_eq(store:last_event().kind, 'session_created')

	now = 102
	store:prune()
	assert_eq(store:last_event().kind, 'session_pruned')
	assert_eq(store:last_event().session_ids[1], 's2')
	assert_eq(store:last_event().count, 0)
end

function tests.test_expired_session_get_is_pure_and_prune_records_event()
	local now = 100
	local store = sessions.new({
		now = function() return now end,
	})
	store:create('alice', { id = 's1', ttl = 1 })
	local created = store:last_event()
	assert_eq(created.kind, 'session_created')
	now = 102
	assert_nil(store:get('s1'))
	assert_eq(store:last_event().kind, 'session_created')
	assert_eq(store:count(), 0)
	local removed = store:prune()
	assert_eq(removed[1], 's1')
	assert_eq(store:last_event().kind, 'session_pruned')
	assert_eq(store:last_event().session_ids[1], 's1')
	assert_eq(store:last_event().count, 0)
end


function tests.test_session_mutations_signal_versioned_changed_op()
	local fibers = require 'fibers'
	fibers.run(function()
		local now = 100
		local store = sessions.new({ now = function() return now end, default_ttl = 10 })
		local seen = store:version()

		store:create('alice', { id = 's1' })
		local version, snap, err = fibers.perform(store:changed_op(seen))
		assert_nil(err)
		assert_eq(version, 1)
		assert_eq(snap.count, 1)
		assert_eq(snap.last_event.kind, 'session_created')
		assert_eq(snap.last_event.session_id, 's1')

		local v2, _, e2 = fibers.perform(store:changed_op(version):or_else(function()
			return nil, nil, 'not_ready'
		end))
		assert_nil(v2)
		assert_eq(e2, 'not_ready')
	end)
end

function tests.test_session_store_ignores_legacy_event_sink_options()
	local now = 100
	local called = false
	local store = sessions.new({
		now = function() return now end,
		on_event = function() called = true end,
		event_sink = function() called = true end,
	})

	local sess = store:create('alice', { id = 's1' })
	assert_eq(sess.id, 's1')
	assert_eq(store:count(), 1)
	assert_eq(store:version(), 1)
	assert_eq(called, false)
	assert_eq(store:last_event().kind, 'session_created')
end

return tests
