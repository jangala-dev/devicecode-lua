local fibers = require 'fibers'
local mailbox = require 'fibers.mailbox'
local op = require 'fibers.op'
local store_cap = require 'services.update.artifacts.store_cap'
local bundled_probe = require 'services.update.bundled_probe'
local bundled = require 'services.update.bundled'

local tests = {}
local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a,b,msg) if a ~= b then fail(msg or ('expected '..tostring(b)..', got '..tostring(a))) end end
local function assert_true(v,msg) if v ~= true then fail(msg or ('expected true, got '..tostring(v))) end end

local function probe_store()
	return store_cap.wrap({
		probe_op = function (_, source)
			return op.always({ identity = source.identity or 'desired-1' }, nil)
		end,
	})
end

function tests.test_bundled_probe_reports_completion_without_inline_policy()
	fibers.run(function (scope)
		local tx, rx = mailbox.new(4, { full = 'reject_newest' })
		local handle = assert(bundled_probe.start({
			lifetime_scope = scope,
			report_scope = scope,
			service_id = 'update',
			generation = 7,
			component = 'cm5',
			artifact_store = probe_store(),
			source = { identity = 'image-a' },
			done_tx = tx,
		}))
		assert_true(handle ~= nil)
		local ev = fibers.perform(rx:recv_op())
		assert_eq(ev.kind, 'bundled_probe_done')
		assert_eq(ev.status, 'ok')
		assert_eq(ev.result.desired.identity, 'image-a')
	end)
end

function tests.test_bundled_coordinator_starts_probe_and_applies_stored_result()
	fibers.run(function (scope)
		local tx, rx = mailbox.new(4, { full = 'reject_newest' })
		local co = bundled.new({ service_id = 'update', generation = 3 })
		assert(co:start_probe({
			lifetime_scope = scope,
			report_scope = scope,
			component = 'cm5',
			artifact_store = probe_store(),
			source = { identity = 'desired-cm5' },
			done_tx = tx,
		}))
		local ev = fibers.perform(rx:recv_op())
		assert_true(co:handle_probe_done(ev))
		local snap = co:snapshot()
		assert_eq(snap.state.cm5, 'desired_known')
		assert_eq(snap.desired.cm5.identity, 'desired-cm5')
	end)
end

return tests
