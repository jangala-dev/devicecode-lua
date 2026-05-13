-- tests/unit/ui/test_read_model.lua

local fibers = require 'fibers'
local read_model = require 'services.ui.read_model'
local store_mod = require 'services.ui.read_model_store'
local watches_mod = require 'services.ui.read_model_watches'
local run_fibers = require 'tests.support.run_fibers'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a, b, msg) if a ~= b then fail(msg or ('expected '..tostring(b)..', got '..tostring(a))) end end
local function assert_nil(v, msg) if v ~= nil then fail(msg or ('expected nil, got '..tostring(v))) end end
local function assert_not_nil(v, msg) if v == nil then fail(msg or 'expected non-nil') end end

function tests.test_store_snapshot_changed_op_and_material_change()
	run_fibers.run(function ()
		local model = read_model.new()
		local seen = model:version()

		model:set({ 'svc', 'ui', 'status' }, { state = 'running' })
		local version, snap, err = fibers.perform(model:changed_op(seen))
		assert_nil(err)
		assert_eq(version, 1)
		assert_not_nil(snap.items)

		local a, b = fibers.perform(model:changed_op(version):or_else(function ()
			return nil, 'not_ready'
		end))
		assert_nil(a)
		assert_eq(b, 'not_ready')

		model:set({ 'svc', 'ui', 'status' }, { state = 'running' })
		local c, d = fibers.perform(model:changed_op(version):or_else(function ()
			return nil, 'not_ready'
		end))
		assert_nil(c)
		assert_eq(d, 'not_ready')
	end)
end

function tests.test_store_close_changed_op_returns_reason_shape()
	run_fibers.run(function ()
		local model = store_mod.new()
		local seen = model:version()
		model:terminate('done')
		local version, snap, err = fibers.perform(model:changed_op(seen))
		assert_nil(version)
		assert_nil(snap)
		assert_eq(err, 'done')
	end)
end

function tests.test_watch_replay_overflow_fails_open()
	run_fibers.run(function ()
		local model = store_mod.new()
		local watch_owner = watches_mod.new(model)
		model:set({ 'state', 'a' }, 1)
		model:set({ 'state', 'b' }, 2)

		local watch, err = watch_owner:watch_open({ 'state', '#' }, { queue_len = 1, full = 'reject_newest' })
		assert_nil(watch)
		assert_eq(err, 'watch_replay_overflow')
	end)
end


function tests.test_watch_replay_default_bound_fails_large_replay()
	run_fibers.run(function ()
		local model = store_mod.new()
		local watch_owner = watches_mod.new(model)
		for i = 1, watches_mod.DEFAULT_MAX_REPLAY + 1 do
			model:set({ 'state', i }, i)
		end

		local watch, err = watch_owner:watch_open({ 'state', '#' }, { queue_len = 128, full = 'reject_newest' })
		assert_nil(watch)
		assert_eq(err, 'watch_replay_overflow')
	end)
end

function tests.test_watch_receives_live_events_and_closes_on_overflow()
	run_fibers.run(function ()
		local model = store_mod.new()
		local watch_owner = watches_mod.new(model)
		local watch = assert(watch_owner:watch_open({ 'state', '#' }, { queue_len = 1, replay = false }))
		watch_owner:set({ 'state', 'a' }, 1)
		local ev = fibers.perform(watch:recv_op())
		assert_eq(ev.op, 'set')
		assert_eq(ev.topic[1], 'state')

		watch_owner:set({ 'state', 'b' }, 2)
		watch_owner:set({ 'state', 'c' }, 3)
		assert_eq(watch:why(), 'watch_overflow')
	end)
end

function tests.test_read_model_start_uses_supplied_store_and_watch_owner()
	run_fibers.run(function (scope)
		local store = store_mod.new()
		local watch_owner = watches_mod.new(store)
		local returned_store, returned_watches = read_model.start(scope, nil, {
			model = store,
			watch_owner = watch_owner,
		})
		assert_eq(returned_store, store)
		assert_eq(returned_watches, watch_owner)

		local watch = assert(watch_owner:watch_open({ 'svc', '#' }, { replay = false }))
		watch_owner:ingest({ op = 'retain', topic = { 'svc', 'ui' }, payload = { status = 'running' } })
		local ev = fibers.perform(watch:recv_op())
		assert_eq(ev.op, 'set')
		assert_eq(store:get({ 'svc', 'ui' }).payload.status, 'running')
	end)
end

function tests.test_query_limited_stops_before_materialising_large_replay()
	local model = store_mod.new()
	for i = 1, 5 do model:set({ 'state', i }, i) end
	local items, err = model:query_limited({ 'state', '#' }, 3)
	assert_nil(items)
	assert_eq(err, 'query_limit_exceeded')
	items, err = model:query_limited({ 'state', '#' }, 5)
	assert_not_nil(items, err)
	assert_eq(#items, 5)
end

function tests.test_read_model_query_uses_first_token_index_for_replay_candidates()
	local model = store_mod.new()
	for i = 1, 10 do model:set({ 'state', i }, i) end
	model:set({ 'svc', 'ui' }, 'ui')
	model:set({ 'svc', 'fabric' }, 'fabric')

	assert_eq(store_mod._test.candidate_count(model, { 'svc', '#' }), 2)
	assert_eq(store_mod._test.candidate_count(model, { 'state', '#' }), 10)
	assert_eq(store_mod._test.candidate_count(model, { '#'}), 12)

	local items, err = model:query_limited({ 'svc', '#' }, 2)
	assert_not_nil(items, err)
	assert_eq(#items, 2)
end

function tests.test_read_model_index_updates_on_delete()
	local model = store_mod.new()
	model:set({ 'svc', 'ui' }, 'ui')
	model:set({ 'svc', 'fabric' }, 'fabric')
	assert_eq(store_mod._test.candidate_count(model, { 'svc', '#' }), 2)
	model:delete({ 'svc', 'ui' })
	assert_eq(store_mod._test.candidate_count(model, { 'svc', '#' }), 1)
	local items = model:query({ 'svc', '#' })
	assert_eq(#items, 1)
	assert_eq(items[1].topic[2], 'fabric')
end

return tests
