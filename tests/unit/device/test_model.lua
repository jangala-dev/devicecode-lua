-- tests/unit/device/test_model.lua

local fibers = require 'fibers'
local mailbox = require 'fibers.mailbox'
local sleep = require 'fibers.sleep'
local queue = require 'devicecode.support.queue'
local config = require 'services.device.config'
local model_mod = require 'services.device.model'
local topics = require 'services.device.topics'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a, b, msg) if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end end
local function assert_true(v, msg) if v ~= true then fail(msg or ('expected true, got ' .. tostring(v))) end end
local function assert_false(v, msg) if v ~= false then fail(msg or ('expected false, got ' .. tostring(v))) end end
local function assert_nil(v, msg) if v ~= nil then fail(msg or ('expected nil, got ' .. tostring(v))) end end
local function assert_not_nil(v, msg) if v == nil then fail(msg or 'expected non-nil') end end

local function catalogue_one()
	return assert(config.to_catalogue({
		schema = config.SCHEMA,
		components = {
			mcu = {
				subtype = 'mcu',
				facts = { software = topics.raw_member_state('mcu', 'software') },
			},
		},
	}))
end

function tests.test_snapshot_returns_copy()
	fibers.run(function ()
		local m = model_mod.new()
		m:apply_catalogue(1, catalogue_one())
		local snap = m:snapshot()
		snap.components.mcu.subtype = 'mutated'
		assert_eq(m:snapshot().components.mcu.subtype, 'mcu')
	end)
end

function tests.test_observation_updates_current_generation_only()
	fibers.run(function ()
		local m = model_mod.new()
		m:apply_catalogue(7, catalogue_one())
		local changed, _, err = m:apply_observation(6, {
			component = 'mcu', tag = 'fact_retained', fact = 'software', payload = { version = 'old' },
		})
		assert_false(changed)
		assert_eq(err, 'stale_generation')
		assert_nil(m:snapshot().components.mcu.raw_facts.software)

		changed, _, err = m:apply_observation(7, {
			component = 'mcu', tag = 'fact_retained', fact = 'software', payload = { version = '1.0' },
		})
		assert_true(changed)
		assert_nil(err)
		assert_eq(m:snapshot().components.mcu.raw_facts.software.version, '1.0')
	end)
end

function tests.test_changed_op_wakes_on_material_change()
	fibers.run(function (scope)
		local m = model_mod.new()
		local seen = m:version()
		local tx, rx = mailbox.new(1, { full = 'reject_newest' })
		local ok, err = scope:spawn(function ()
			local version, snap, cerr = fibers.perform(m:changed_op(seen))
			queue.assert_admit_required(tx, { version = version, snap = snap, err = cerr }, 'device_model_changed')
		end)
		assert_true(ok, err)
		fibers.perform(sleep.sleep_op(0.001))
		m:apply_catalogue(1, catalogue_one())
		local got = fibers.perform(rx:recv_op())
		assert_not_nil(got)
		assert_eq(got.version, seen + 1)
		assert_nil(got.err)
	end)
end

function tests.test_terminate_wakes_changed_op_with_reason()
	fibers.run(function (scope)
		local m = model_mod.new()
		local seen = m:version()
		local tx, rx = mailbox.new(1, { full = 'reject_newest' })
		local ok, err = scope:spawn(function ()
			local version, snap, cerr = fibers.perform(m:changed_op(seen))
			queue.assert_admit_required(tx, { version = version, snap = snap, err = cerr }, 'device_model_terminated')
		end)
		assert_true(ok, err)
		fibers.perform(sleep.sleep_op(0.001))
		assert_true(m:terminate('test_done'))
		local got = fibers.perform(rx:recv_op())
		assert_not_nil(got)
		assert_nil(got.version)
		assert_eq(got.err, 'test_done')
		assert_true(m:is_terminated())
		assert_true(m:terminate('ignored'))
		assert_eq(m:why(), 'test_done')
	end)
end

return tests
