-- tests/unit/fabric/test_model.lua

local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'
local mailbox = require 'fibers.mailbox'

local model_mod = require 'services.fabric.model'
local queue     = require 'devicecode.support.queue'

local tests = {}

local function fail(msg)
	error(msg or 'assertion failed', 2)
end

local function assert_true(v, msg)
	if v ~= true then
		fail(msg or ('expected true, got ' .. tostring(v)))
	end
end

local function assert_false(v, msg)
	if v ~= false then
		fail(msg or ('expected false, got ' .. tostring(v)))
	end
end

local function assert_nil(v, msg)
	if v ~= nil then
		fail(msg or ('expected nil, got ' .. tostring(v)))
	end
end

local function assert_not_nil(v, msg)
	if v == nil then
		fail(msg or 'expected non-nil value')
	end
end

local function assert_eq(a, b, msg)
	if a ~= b then
		fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a)))
	end
end

-------------------------------------------------------------------------------
-- snapshot returns a copy
-------------------------------------------------------------------------------

function tests.test_snapshot_returns_copy()
	fibers.run(function ()
		local m = model_mod.new({ state = 'idle', count = 1 })

		local snap = m:snapshot()
		snap.state = 'mutated'
		snap.count = 99

		local snap2 = m:snapshot()

		assert_eq(snap2.state, 'idle')
		assert_eq(snap2.count, 1)
	end)
end

-------------------------------------------------------------------------------
-- set_snapshot does not signal when materially unchanged
-------------------------------------------------------------------------------

function tests.test_set_snapshot_unchanged_does_not_increment_version()
	fibers.run(function ()
		local m = model_mod.new({ state = 'idle', count = 1 })

		local v0 = m:version()

		local changed, v = m:set_snapshot({ state = 'idle', count = 1 })

		assert_false(changed)
		assert_eq(v, v0)
		assert_eq(m:version(), v0)
	end)
end

-------------------------------------------------------------------------------
-- set_snapshot signals on material change
-------------------------------------------------------------------------------

function tests.test_set_snapshot_changed_increments_version()
	fibers.run(function ()
		local m = model_mod.new({ state = 'idle', count = 1 })

		local v0 = m:version()

		local changed, v1 = m:set_snapshot({ state = 'ready', count = 1 })

		assert_true(changed)
		assert_eq(v1, v0 + 1)
		assert_eq(m:version(), v0 + 1)

		local snap = m:snapshot()
		assert_eq(snap.state, 'ready')
		assert_eq(snap.count, 1)
	end)
end

-------------------------------------------------------------------------------
-- changed_op returns a versioned snapshot when already stale
-------------------------------------------------------------------------------

function tests.test_changed_op_returns_immediately_when_version_is_stale()
	fibers.run(function ()
		local m = model_mod.new({ state = 'idle' })

		local seen = m:version()

		m:set_snapshot({ state = 'ready' })

		local version, snap, err = fibers.perform(m:changed_op(seen))

		assert_eq(version, seen + 1)
		assert_eq(snap.state, 'ready')
		assert_nil(err)
	end)
end

-------------------------------------------------------------------------------
-- changed_op waits and returns versioned snapshot
-------------------------------------------------------------------------------

function tests.test_changed_op_waits_for_change()
	fibers.run(function (scope)
		local m = model_mod.new({ state = 'idle' })
		local seen = m:version()

		local tx, rx = mailbox.new(1, { full = 'reject_newest' })

		local ok, err = scope:spawn(function ()
			local version, snap, cerr = fibers.perform(m:changed_op(seen))
			queue.assert_admit_required(tx, {
				version = version,
				snap    = snap,
				err     = cerr,
			}, 'model_change_result')
		end)

		assert_true(ok, err)

		-- Let the waiter reach changed_op.
		fibers.perform(sleep.sleep_op(0.001))

		m:set_snapshot({ state = 'ready' })

		local result = fibers.perform(rx:recv_op())

		assert_not_nil(result)
		assert_eq(result.version, seen + 1)
		assert_eq(result.snap.state, 'ready')
		assert_nil(result.err)
	end)
end

-------------------------------------------------------------------------------
-- terminate wakes up-to-date observers with a reason
-------------------------------------------------------------------------------

function tests.test_terminate_wakes_observer_with_reason()
	fibers.run(function (scope)
		local m = model_mod.new({ state = 'idle' })
		local seen = m:version()

		local tx, rx = mailbox.new(1, { full = 'reject_newest' })

		local ok, err = scope:spawn(function ()
			local version, snap, cerr = fibers.perform(m:changed_op(seen))
			queue.assert_admit_required(tx, {
				version = version,
				snap    = snap,
				err     = cerr,
			}, 'model_terminate_result')
		end)

		assert_true(ok, err)

		fibers.perform(sleep.sleep_op(0.001))

		m:terminate('model stopped')

		local result = fibers.perform(rx:recv_op())

		assert_not_nil(result)
		assert_nil(result.version)
		assert_nil(result.snap)
		assert_eq(result.err, 'model stopped')
	end)
end

-------------------------------------------------------------------------------
-- terminate is idempotent and preserves first reason
-------------------------------------------------------------------------------

function tests.test_close_is_idempotent_and_preserves_first_reason()
	fibers.run(function ()
		local m = model_mod.new({ state = 'idle' })

		assert_true(m:terminate('first'))
		assert_true(m:terminate('second'))

		assert_true(m:is_closed())
		assert_eq(m:why(), 'first')
	end)
end

-------------------------------------------------------------------------------
-- set_snapshot after terminate fails without changing version
-------------------------------------------------------------------------------

function tests.test_set_snapshot_after_terminate_fails_without_incrementing_version()
	fibers.run(function ()
		local m = model_mod.new({ state = 'idle' })

		local v0 = m:version()

		m:terminate('closed_for_test')

		local changed, err = m:set_snapshot({ state = 'ready' })

		assert_nil(changed)
		assert_eq(err, 'closed_for_test')
		assert_eq(m:version(), v0)

		local snap = m:snapshot()
		assert_eq(snap.state, 'idle')
	end)
end

-------------------------------------------------------------------------------
-- stale observer after close still sees unseen snapshot first
-------------------------------------------------------------------------------

function tests.test_stale_observer_after_close_sees_unseen_snapshot_first()
	fibers.run(function ()
		local m = model_mod.new({ state = 'idle' })

		local seen = m:version()

		m:set_snapshot({ state = 'ready' })
		m:terminate('closed_after_change')

		local version, snap, err = fibers.perform(m:changed_op(seen))

		assert_eq(version, seen + 1)
		assert_eq(snap.state, 'ready')
		assert_nil(err)

		local version2, snap2, err2 = fibers.perform(m:changed_op(version))

		assert_nil(version2)
		assert_nil(snap2)
		assert_eq(err2, 'closed_after_change')
	end)
end

return tests
