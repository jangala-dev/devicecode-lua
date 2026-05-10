-- tests/unit/device/test_service.lua

local fibers = require 'fibers'
local sleep = require 'fibers.sleep'
local mailbox = require 'fibers.mailbox'
local service = require 'services.device.service'
local device = require 'services.device'
local config = require 'services.device.config'
local topics = require 'services.device.topics'

local tests = {}
local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a, b, msg) if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end end
local function assert_true(v, msg) if v ~= true then fail(msg or ('expected true, got ' .. tostring(v))) end end
local function assert_nil(v, msg) if v ~= nil then fail(msg or ('expected nil, got ' .. tostring(v))) end end
local function assert_not_nil(v, msg) if v == nil then fail(msg or 'expected non-nil') end end

local function key(topic) return table.concat(topic, '/') end
local function fake_conn()
	local c = { retained = {}, published = {}, binds = {}, subscriptions = {}, retain_calls = 0, unretain_calls = 0, publish_calls = 0, bind_calls = 0, unbind_calls = 0, subscribe_calls = 0, unsubscribe_calls = 0 }
	function c:retain(topic, payload) self.retain_calls = self.retain_calls + 1; self.retained[key(topic)] = payload; return true end
	function c:unretain(topic)
		self.unretain_calls = self.unretain_calls + 1
		if self.fail_unretain then return false, self.fail_unretain end
		self.retained[key(topic)] = nil
		return true
	end
	function c:publish(topic, payload) self.publish_calls = self.publish_calls + 1; self.published[#self.published + 1] = { topic = topic, payload = payload }; return true end
	function c:bind(topic, opts)
		self.bind_calls = self.bind_calls + 1
		local ep = { topic = topic, opts = opts, id = 'ep-' .. tostring(self.bind_calls) }
		self.binds[ep.id] = ep
		return ep
	end
	function c:subscribe(topic, opts)
		self.subscribe_calls = self.subscribe_calls + 1
		local _tx, rx = mailbox.new(4, { full = 'reject_newest' })
		local sub = { topic = topic, opts = opts, id = 'sub-' .. tostring(self.subscribe_calls), rx = rx }
		function sub:recv_op() return self.rx:recv_op() end
		self.subscriptions[sub.id] = sub
		return sub
	end
	function c:unsubscribe(sub)
		self.unsubscribe_calls = self.unsubscribe_calls + 1
		if sub and sub.id then self.subscriptions[sub.id] = nil end
		return true
	end
	function c:unbind(ep)
		self.unbind_calls = self.unbind_calls + 1
		if self.fail_unbind then return false, self.fail_unbind end
		if ep and ep.id then self.binds[ep.id] = nil end
		return true
	end
	return c
end

local function cfg_one(extra)
	local c = {
		schema = config.SCHEMA,
		components = {
			mcu = { subtype = 'mcu', facts = { software = topics.raw_member_state('mcu', 'software') } },
		},
	}
	if extra then for k, v in pairs(extra) do c[k] = v end end
	return c
end


function tests.test_start_requires_conn_and_fiber()
	local ok, err = pcall(function () service.start(nil, { watch_config = false }) end)
	assert_eq(ok, false)
	assert_true(tostring(err):find('conn required', 1, true) ~= nil, tostring(err))

	ok, err = pcall(function () service.start(fake_conn(), { watch_config = false }) end)
	assert_eq(ok, false)
	assert_true(tostring(err):find('inside a fiber', 1, true) ~= nil, tostring(err))
end


function tests.test_start_opens_cfg_device_with_shared_config_watch_and_closes_it()
	fibers.run(function ()
		local conn = fake_conn()
		local st, _rep, primary = fibers.run_scope(function (scope)
			assert_true(scope:spawn(function ()
				device.start(conn, {
					auto_publish = false,
					enable_actions = false,
					enable_observers = false,
				})
			end))
			fibers.perform(sleep.sleep_op(0.001))
			assert_eq(conn.subscribe_calls, 1)
			local sub = conn.subscriptions['sub-1']
			assert_not_nil(sub)
			assert_eq(key(sub.topic), 'cfg/device')
			scope:cancel('test_stop')
		end)

		assert_eq(st, 'cancelled')
		assert_eq(primary, 'test_stop')
		assert_eq(conn.unsubscribe_calls, 1)
		assert_nil(conn.subscriptions['sub-1'])
	end)
end

function tests.test_start_publishes_service_lifecycle_status()
	fibers.run(function ()
		local conn = fake_conn()
		local seen = {}
		local parent_retain = conn.retain
		function conn:retain(topic, payload)
			local k = key(topic)
			if k == 'svc/device/status' then
				seen[#seen + 1] = payload.state .. ':' .. tostring(payload.ready)
			end
			return parent_retain(self, topic, payload)
		end

		local st, _rep, primary = fibers.run_scope(function (scope)
			assert_true(scope:spawn(function ()
				device.start(conn, {
					watch_config = false,
					auto_publish = false,
					enable_actions = false,
					enable_observers = false,
				})
			end))
			fibers.perform(sleep.sleep_op(0.001))
			scope:cancel('test_stop')
		end)

		assert_eq(st, 'cancelled')
		assert_eq(primary, 'test_stop')
		assert_true(seen[1] == 'starting:false' or seen[1] == 'running:false', 'missing starting lifecycle status')
		assert_true(seen[#seen]:find('stopped:false', 1, true) ~= nil, 'missing stopped lifecycle status')
		assert_nil(conn.retained['svc/device/status'], 'service_base finaliser should unretain lifecycle topics')
	end)
end

function tests.test_apply_config_starts_generation_and_publishes_public_state()
	fibers.run(function (scope)
		local conn = fake_conn()
		local state = service.build_state(scope, {
			conn = conn,
			enable_actions = false,
			enable_observers = false,
			now = function () return 100 end,
		})

		local ok, err = service.apply_config_payload(state, cfg_one())
		assert_true(ok, err)
		assert_eq(state.active.generation, 1)
		assert_eq(state.model:snapshot().components.mcu.subtype, 'mcu')

		ok, err = service.flush_publication(state)
		assert_true(ok, err)
		assert_eq(conn.retained['state/device/component/mcu'].component, 'mcu')
		assert_eq(conn.retained['state/device/components'].counts.total, 1)
	end)
end

function tests.test_same_effective_catalogue_does_not_restart_generation()
	fibers.run(function (scope)
		local state = service.build_state(scope, {
			conn = fake_conn(),
			enable_actions = false,
			enable_observers = false,
		})
		assert_true(service.apply_config_payload(state, cfg_one()))
		local generation = state.active.generation
		assert_true(service.apply_config_payload(state, cfg_one()))
		assert_eq(state.active.generation, generation)
	end)
end

function tests.test_material_catalogue_change_replaces_generation()
	fibers.run(function (scope)
		local state = service.build_state(scope, {
			conn = fake_conn(),
			enable_actions = false,
			enable_observers = false,
		})
		assert_true(service.apply_config_payload(state, cfg_one()))
		local first = state.active
		assert_true(first.observer_root ~= nil, 'observer root was not created')
		assert_true(first.action_root ~= nil, 'action root was not created')
		assert_true(service.apply_config_payload(state, cfg_one({ components = {
			mcu = { subtype = 'mcu', facts = { software = topics.raw_member_state('mcu', 'software') } },
			host = { class = 'host', subtype = 'cm5', facts = { software = topics.raw_host_cap_state('updater', 'updater', 'cm5', 'software') } },
		} })))
		assert_eq(state.active.generation, 2)
		local st = first.scope:status()
		assert_eq(st, 'cancelled')
		local observer_st = first.observer_root:status()
		local action_st = first.action_root:status()
		assert_eq(observer_st, 'cancelled')
		assert_eq(action_st, 'cancelled')
	end)
end

function tests.test_publication_coalesces_repeated_materially_identical_observation()
	fibers.run(function (scope)
		local conn = fake_conn()
		local state = service.build_state(scope, {
			conn = conn,
			enable_actions = false,
			enable_observers = false,
			now = function () return 100 end,
		})

		assert_true(service.apply_config_payload(state, cfg_one()))
		assert_true(service.flush_publication(state))

		local ev = {
			kind = 'component_observation',
			generation = state.active.generation,
			component = 'mcu',
			tag = 'fact_retained',
			fact = 'software',
			payload = { version = '1.0' },
			at = 123,
		}

		assert_true(service.reduce_event(state, ev))
		assert_true(service.flush_publication(state))
		local retain_after_first = conn.retain_calls
		local publish_after_first = conn.publish_calls

		assert_true(service.reduce_event(state, ev))
		assert_true(service.flush_publication(state))
		assert_eq(conn.retain_calls, retain_after_first)
		assert_eq(conn.publish_calls, publish_after_first)
	end)
end


function tests.test_publication_is_selected_as_semantic_event_after_dirty_change()
	fibers.run(function (scope)
		local conn = fake_conn()
		local state = service.build_state(scope, {
			conn = conn,
			enable_actions = false,
			enable_observers = false,
			now = function () return 100 end,
		})

		assert_true(service.apply_config_payload(state, cfg_one()))
		assert_eq(conn.retain_calls, 0, 'configuration should mark publication dirty, not publish inline')
		assert_true(state.publication_requested)

		local ev = fibers.perform(service.next_event_op(state))
		assert_eq(ev.kind, 'publication_flush')
		assert_true(service.reduce_event(state, ev))
		assert_eq(state.publication_requested, false)
		assert_eq(conn.retained['state/device/component/mcu'].component, 'mcu')
	end)
end


local function count_keys(t)
	local n = 0
	for _ in pairs(t or {}) do n = n + 1 end
	return n
end

function tests.test_unbind_failure_during_generation_replacement_is_surfaced_and_records_kept()
	fibers.run(function (scope)
		local conn = fake_conn()
		local state = service.build_state(scope, {
			conn = conn,
			enable_observers = false,
			auto_publish = false,
		})

		local ok, err = service.apply_config_payload(state, cfg_one())
		assert_true(ok, err)
		local first = state.active
		assert_not_nil(first)
		assert_true(count_keys(first.action_eps) > 0, 'first generation should expose action endpoints')

		conn.fail_unbind = 'synthetic unbind failure'
		ok, err = service.apply_config_payload(state, cfg_one({ components = {
			mcu = { subtype = 'mcu', facts = { software = topics.raw_member_state('mcu', 'software') } },
			host = { class = 'host', subtype = 'cm5', facts = { software = topics.raw_host_cap_state('updater', 'updater', 'cm5', 'software') } },
		} }))

		assert_nil(ok)
		assert_true(tostring(err):find('synthetic unbind failure', 1, true) ~= nil, tostring(err))
		assert_true(count_keys(first.action_eps) > 0, 'old endpoint records must not be cleared when unbind fails')

		-- Let the enclosing test scope finalisers clean up the generation.
		conn.fail_unbind = nil
	end)
end

function tests.test_publication_cleanup_is_checked_and_keeps_records_on_failure()
	fibers.run(function (scope)
		local conn = fake_conn()
		local state = service.build_state(scope, {
			conn = conn,
			enable_actions = false,
			enable_observers = false,
			now = function () return 100 end,
		})
		assert_true(service.apply_config_payload(state, cfg_one()))
		assert_true(service.flush_publication(state))
		assert_true(state.published_components.mcu)

		conn.fail_unretain = 'synthetic unretain failure'
		local ok, err = service.cleanup_publication_now(state)
		assert_nil(ok)
		assert_true(tostring(err):find('synthetic unretain failure', 1, true) ~= nil, tostring(err))
		assert_true(state.published_components.mcu, 'publication record must remain until durable cleanup succeeds')

		-- Let the enclosing test scope finalisers clean up retained publication.
		conn.fail_unretain = nil
	end)
end


function tests.test_cleanup_publication_ignores_summary_identity_when_never_published()
	fibers.run(function (scope)
		local state = service.build_state(scope, {
			conn = {},
			enable_actions = false,
			enable_observers = false,
		})

		local ok, err = service.cleanup_publication_now(state)
		assert_true(ok, err)
	end)
end

return tests
