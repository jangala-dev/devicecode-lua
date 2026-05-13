-- tests/unit/update/test_events.lua

local fibers = require 'fibers'
local mailbox = require 'fibers.mailbox'

local events = require 'services.update.events'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a, b, msg) if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end end

function tests.test_next_event_prefers_generation_done_over_manager_when_both_ready()
	fibers.run(function ()
		local done_tx, done_rx = mailbox.new(4, { full = 'reject_newest' })
		local mgr_tx, mgr_rx = mailbox.new(4, { full = 'reject_newest' })

		done_tx:send({ kind = 'generation_done', generation = 1 })
		mgr_tx:send({ fake = 'request' })

		local ev = fibers.perform(events.next_service_event_op({
			pending = {},
			done_rx = done_rx,
			manager_rx = mgr_rx,
		}))

		assert_eq(ev.kind, 'generation_done')
	end)
end

function tests.test_next_event_rechecks_priority_after_wake()
	fibers.run(function (scope)
		local done_tx, done_rx = mailbox.new(4, { full = 'reject_newest' })
		local mgr_tx, mgr_rx = mailbox.new(4, { full = 'reject_newest' })

		local state = {
			pending = {},
			done_rx = done_rx,
			manager_rx = mgr_rx,
		}

		local seen
		local ok, err = scope:spawn(function ()
			seen = fibers.perform(events.next_service_event_op(state))
		end)
		if not ok then fail(err) end

		-- Wake via manager, then make a higher-priority completion ready before
		-- the selector commits. The helper stores the wake and re-runs priority.
		mgr_tx:send({ fake = 'request' })
		done_tx:send({ kind = 'generation_done', generation = 2 })

		while seen == nil do fibers.perform(require('fibers.sleep').sleep_op(0.001)) end
		assert_eq(seen.kind, 'generation_done')
		assert_eq(seen.generation, 2)
	end)
end

function tests.test_map_config_event_accepts_shared_config_watch_shape()
	local ev = events.map_config_event({
		kind = 'config_changed',
		rev = 7,
		generation = 3,
		record = { rev = 7, data = { namespace = 'shared' } },
		msg = { origin = { kind = 'local' } },
	})
	assert_eq(ev.kind, 'config_changed')
	assert_eq(ev.rev, 7)
	assert_eq(ev.generation, 3)
	assert_eq(ev.payload.data.namespace, 'shared')
	assert_eq(ev.origin.kind, 'local')
end

function tests.test_map_config_event_accepts_shared_config_watch_closed_shape()
	local ev = events.map_config_event({ kind = 'config_watch_closed', err = 'closed_for_test' })
	assert_eq(ev.kind, 'config_watch_closed')
	assert_eq(ev.err, 'closed_for_test')
end

return tests
