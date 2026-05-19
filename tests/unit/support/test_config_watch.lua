local fibers = require 'fibers'
local bus = require 'bus'

local config_watch = require 'devicecode.support.config_watch'

local M = {}

local function eq(a, b, msg)
	if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end

local function ok(v, msg)
	if not v then error(msg or 'assertion failed', 2) end
	return v
end

function M.test_extracts_data_from_retained_config_record()
	local rec = { rev = 12, data = { enabled = true } }
	eq(config_watch._test.data_of(rec), rec.data)
	eq(config_watch._test.rev_of(rec, 0), 12)
end

function M.test_plain_payload_is_supported_for_bootstrap_and_unit_tests()
	local raw = { schema = 'x' }
	eq(config_watch._test.data_of(raw), raw)
	eq(config_watch._test.rev_of(raw, 7), 7)
end

function M.test_standard_cfg_topic_shape()
	local topic = config_watch.topic('ui')
	eq(topic[1], 'cfg')
	eq(topic[2], 'ui')
end

function M.test_open_replays_retained_cfg_record_published_before_watch_creation()
	fibers.run(function ()
		local b = bus.new()
		local conn = b:connect({ origin_base = { kind = 'test' } })
		ok(conn:retain({ 'cfg', 'update' }, {
			rev = 42,
			data = { schema = 'devicecode.config/update/1', enabled = true },
		}))

		local watch, err = config_watch.open(conn, 'update', { queue_len = 2 })
		ok(watch, err)

		local ev, recv_err = fibers.perform(watch:recv_op())
		ok(ev, recv_err)
		eq(ev.kind, 'config_changed')
		eq(ev.service, 'update')
		eq(ev.generation, 42)
		eq(ev.rev, 42)
		eq(ev.raw.enabled, true)
		eq(ev.record.rev, 42)
		eq(ev.msg.topic[1], 'cfg')
		eq(ev.msg.topic[2], 'update')

		ok(watch:close())
	end)
end

function M.test_try_recv_now_can_consume_bootstrap_replay_without_waiting()
	fibers.run(function ()
		local b = bus.new()
		local conn = b:connect({ origin_base = { kind = 'test' } })
		ok(conn:retain({ 'cfg', 'net' }, {
			rev = 3,
			data = { schema = 'devicecode.config/net/1' },
		}))

		local watch, err = config_watch.open(conn, 'net', { queue_len = 1 })
		ok(watch, err)

		local ev = watch:try_recv_now()
		ok(ev, 'retained cfg/net replay should be immediately ready after open')
		eq(ev.kind, 'config_changed')
		eq(ev.service, 'net')
		eq(ev.generation, 3)
		eq(ev.raw.schema, 'devicecode.config/net/1')

		local none, why = watch:try_recv_now()
		eq(none, nil)
		eq(why, nil)

		ok(watch:close())
	end)
end

function M.test_watch_receives_live_cfg_after_retained_bootstrap()
	fibers.run(function ()
		local b = bus.new()
		local conn = b:connect({ origin_base = { kind = 'test' } })
		ok(conn:retain({ 'cfg', 'ui' }, { rev = 1, data = { enabled = false } }))

		local watch, err = config_watch.open(conn, 'ui', { queue_len = 3 })
		ok(watch, err)
		local boot = ok(fibers.perform(watch:recv_op()))
		eq(boot.generation, 1)
		eq(boot.raw.enabled, false)

		ok(conn:retain({ 'cfg', 'ui' }, { rev = 2, data = { enabled = true } }))
		local live = ok(fibers.perform(watch:recv_op()))
		eq(live.kind, 'config_changed')
		eq(live.generation, 2)
		eq(live.raw.enabled, true)

		ok(watch:close())
	end)
end

return M
