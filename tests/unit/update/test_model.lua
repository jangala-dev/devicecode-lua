-- tests/unit/update/test_model.lua

local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'
local mailbox = require 'fibers.mailbox'

local model_mod = require 'services.update.model'
local queue = require 'devicecode.support.queue'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a, b, msg) if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end end
local function assert_true(v, msg) if v ~= true then fail(msg or ('expected true, got ' .. tostring(v))) end end
local function assert_false(v, msg) if v ~= false then fail(msg or ('expected false, got ' .. tostring(v))) end end
local function assert_nil(v, msg) if v ~= nil then fail(msg or ('expected nil, got ' .. tostring(v))) end end
local function assert_not_nil(v, msg) if v == nil then fail(msg or 'expected non-nil value') end end

function tests.test_snapshot_returns_deep_copy()
	fibers.run(function ()
		local m = model_mod.new({ state = 'idle', nested = { n = 1 } })
		local snap = m:snapshot()
		snap.nested.n = 99
		assert_eq(m:snapshot().nested.n, 1)
	end)
end

function tests.test_unchanged_snapshot_does_not_signal()
	fibers.run(function ()
		local m = model_mod.new({ a = 1, b = { c = 2 } })
		local v0 = m:version()
		local changed, v = m:set_snapshot({ a = 1, b = { c = 2 } })
		assert_false(changed)
		assert_eq(v, v0)
	end)
end

function tests.test_changed_op_returns_snapshot()
	fibers.run(function (scope)
		local m = model_mod.new({ state = 'idle' })
		local seen = m:version()
		local tx, rx = mailbox.new(1, { full = 'reject_newest' })

		local ok, err = scope:spawn(function ()
			local version, snap, cerr = fibers.perform(m:changed_op(seen))
			queue.assert_admit_required(tx, { version = version, snap = snap, err = cerr }, 'update_model_changed')
		end)
		assert_true(ok, err)

		fibers.perform(sleep.sleep_op(0.001))
		m:set_snapshot({ state = 'ready' })

		local result = fibers.perform(rx:recv_op())
		assert_not_nil(result)
		assert_eq(result.version, seen + 1)
		assert_eq(result.snap.state, 'ready')
		assert_nil(result.err)
	end)
end

function tests.test_terminate_wakes_observer()
	fibers.run(function (scope)
		local m = model_mod.new({ state = 'idle' })
		local seen = m:version()
		local tx, rx = mailbox.new(1, { full = 'reject_newest' })

		local ok, err = scope:spawn(function ()
			local version, snap, cerr = fibers.perform(m:changed_op(seen))
			queue.assert_admit_required(tx, { version = version, snap = snap, err = cerr }, 'update_model_closed')
		end)
		assert_true(ok, err)

		fibers.perform(sleep.sleep_op(0.001))
		m:terminate('closed for test')

		local result = fibers.perform(rx:recv_op())
		assert_nil(result.version)
		assert_nil(result.snap)
		assert_eq(result.err, 'closed for test')
	end)
end

return tests
