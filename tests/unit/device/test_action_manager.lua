-- tests/unit/device/test_action_manager.lua

local fibers = require 'fibers'
local config = require 'services.device.config'
local model_mod = require 'services.device.model'
local action_manager = require 'services.device.action_manager'
local scoped_work = require 'devicecode.support.scoped_work'
local topics = require 'services.device.topics'

local tests = {}
local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a, b, msg) if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end end
local function assert_true(v, msg) if v ~= true then fail(msg or ('expected true, got ' .. tostring(v))) end end
local function assert_nil(v, msg) if v ~= nil then fail(msg or ('expected nil, got ' .. tostring(v))) end end
local function assert_not_nil(v, msg) if v == nil then fail(msg or 'expected non-nil') end end

local function req(payload)
	local r = { payload = payload, replied = nil, failed = nil }
	function r:reply(v) self.replied = v; return true end
	function r:fail(e) self.failed = e; return true end
	return r
end

function tests.test_status_read_is_immediate_model_snapshot()
	local cat = assert(config.to_catalogue({
		schema = config.SCHEMA,
		components = {
			mcu = { subtype = 'mcu', facts = { software = topics.raw_member_state('mcu', 'software') } },
		},
	}))
	local m = model_mod.new()
	m:apply_catalogue(3, cat)
	m:apply_observation(3, { component = 'mcu', tag = 'fact_retained', fact = 'software', payload = { version = '1.0' } })
	local r = req()
	local state = { model = m, now = function () return 10 end }
	local ok, err = action_manager.status_reply(state, r, 'mcu')
	assert_true(ok, err)
	assert_eq(r.replied.component, 'mcu')
	assert_eq(r.replied.software.version, '1.0')
end


function tests.test_action_start_failure_after_request_owner_setup_resolves_once()
	local old_start = scoped_work.start
	local captured_setup
	local captured_setup_finaliser
	local fake_scope = {
		finally = function (_, fn)
			captured_setup_finaliser = fn
			return function () end
		end,
	}

	scoped_work.start = function (spec)
		captured_setup = spec.setup(fake_scope)
		return nil, 'synthetic post-setup action start failure', captured_setup
	end

	local r = { fail_count = 0, failed = nil }
	function r:fail(e)
		self.fail_count = self.fail_count + 1
		self.failed = e
		return true
	end

	local cat = assert(config.to_catalogue({
		schema = config.SCHEMA,
		components = {
			mcu = {
				subtype = 'mcu',
				facts = { software = topics.raw_member_state('mcu', 'software') },
				actions = { restart = { kind = 'rpc', call_topic = topics.raw_member_cap_rpc('mcu', 'control', 'main', 'restart') } },
			},
		},
	}))

	local state = {
		_action_seq = 0,
		scope = {},
		conn = nil,
		done_tx = {},
		pending_actions = {},
		action_timeout = 1,
		active = {
			generation = 11,
			action_root = {},
			catalogue = cat,
		},
	}

	local ok, err = action_manager.start_action(state, r, {
		generation = 11,
		component = 'mcu',
		action = 'restart',
	})

	scoped_work.start = old_start

	assert_nil(ok)
	assert_eq(err, 'synthetic post-setup action start failure')
	assert_eq(r.fail_count, 1)
	assert_eq(r.failed, 'synthetic post-setup action start failure')
	assert_true(captured_setup and captured_setup.request_owner ~= nil, 'setup request owner was not returned')

	-- Later structural cleanup must not resolve the raw request again.
	captured_setup.request_owner:finalise_unresolved('later structural cleanup')
	assert_eq(r.fail_count, 1)
end


function tests.test_dynamic_action_spec_rejects_payload_as_request_failure()
	local rejecting_module = {
		kind = 'mcu',
		action_spec = function (_, _, payload, _)
			if not (type(payload) == 'table' and payload.allowed == true) then
				return nil, 'payload_rejected'
			end
			return { call_topic = topics.raw_member_cap_rpc('mcu', 'control', 'main', 'restart') }
		end,
	}

	local cat = assert(config.to_catalogue({
		schema = config.SCHEMA,
		components = {
			mcu = {
				subtype = 'mcu',
				module = rejecting_module,
				facts = { software = topics.raw_member_state('mcu', 'software') },
				actions = { restart = { kind = 'rpc', call_topic = topics.raw_member_cap_rpc('mcu', 'control', 'main', 'restart') } },
			},
		},
	}))

	local r = req({ denied = true })
	local state = {
		_action_seq = 0,
		pending_actions = {},
		active = {
			generation = 23,
			catalogue = cat,
			action_root = {},
		},
	}

	local ok, err = action_manager.start_action(state, r, {
		generation = 23,
		component = 'mcu',
		action = 'restart',
	})

	assert_true(ok, err)
	assert_nil(err)
	assert_eq(r.failed, 'payload_rejected')
	assert_nil(r.replied)
	assert_eq(next(state.pending_actions), nil, 'rejected request must not admit action work')
end


function tests.test_unbind_generation_skips_unowned_synthetic_event_sources()
	local active = {
		action_eps = {
			['mcu:restart'] = {
				key = 'mcu:restart',
				ep = { recv_op = function () end },
			},
		},
	}

	local ok, err = action_manager.unbind_generation(active, nil)
	assert_true(ok, err)
	assert_eq(next(active.action_eps), nil)
end

function tests.test_action_admission_passes_caller_cancel_op_to_scoped_work()
	local cond = require 'fibers.cond'
	local op = require 'fibers.op'
	fibers.run(function ()
		local old_start = scoped_work.start
		local done = cond.new()
		local r = { payload = {}, _done = false, _status = 'pending', _err = nil }
		function r:reply(_) error('reply must not be called') end
		function r:fail(_) error('fail must not be called') end
		function r:abandon(reason) self._done = true; self._status = 'abandoned'; self._err = reason; done:signal(); return true end
		function r:done_op()
			return op.guard(function ()
				if self._done then return op.always(self._status, nil, self._err) end
				return done:wait_op():wrap(function () return self._status, nil, self._err end)
			end)
		end

		scoped_work.start = function (spec)
			assert_not_nil(spec.cancel_op, 'action scoped_work must receive caller cancel_op')
			local fake_scope = { finally = function () return function () end end }
			local setup = assert(spec.setup(fake_scope))
			r:abandon('user_timeout')
			local reason = fibers.perform(spec.cancel_op)
			assert_eq(reason, 'user_timeout')
			assert_true(setup.request_owner:done(), 'caller cancellation should abandon local owner')
			return { cancel = function () return true end }, nil
		end

		local cat = assert(config.to_catalogue({
			schema = config.SCHEMA,
			components = {
				mcu = {
					subtype = 'mcu',
					facts = { software = topics.raw_member_state('mcu', 'software') },
					actions = { restart = { kind = 'rpc', call_topic = topics.raw_member_cap_rpc('mcu', 'control', 'main', 'restart') } },
				},
			},
		}))

		local state = {
			_action_seq = 0,
			scope = {},
			conn = nil,
			done_tx = {},
			pending_actions = {},
			action_timeout = 1,
			active = { generation = 31, action_root = {}, catalogue = cat },
		}

		local ok, err = action_manager.start_action(state, r, { generation = 31, component = 'mcu', action = 'restart' })
		scoped_work.start = old_start
		assert_true(ok, err)
	end)
end

return tests
