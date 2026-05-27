-- tests/unit/net/test_service_behaviour.lua

local fibers = require 'fibers'
local sleep = require 'fibers.sleep'
local op = require 'fibers.op'
local busmod = require 'bus'

local service = require 'services.net.service'
local cfg_mod = require 'services.net.config'
local topics = require 'services.net.topics'
local probe = require 'tests.support.bus_probe'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function ok(v, msg) if not v then fail(msg) end return v end
local function eq(a, b, msg) if a ~= b then fail((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function contains(s, needle, msg) if type(s) ~= 'string' or not s:find(needle, 1, true) then fail(msg or ('expected ' .. tostring(s) .. ' to contain ' .. tostring(needle))) end end

local function cfg()
	return {
		schema = cfg_mod.SCHEMA,
		version = 1,
		segments = {
			lan = { kind = 'lan', vlan = 10, addressing = { ipv4 = { mode = 'static', cidr = '172.28.10.1/24' } } },
		},
		interfaces = {
			lan_bridge = { kind = 'bridge', role = 'lan', segment = 'lan', members = { 'eth0' } },
		},
		wan = { members = {} },
	}
end

local function success_hal(calls)
	return {
		available = function () return true end,
		apply_intent_op = function (_, intent, opts)
			calls[#calls + 1] = { intent = intent, opts = opts }
			return op.always({
				ok = true,
				applied = true,
				changed = true,
				backend = 'test',
				intent_rev = intent.rev,
			})
		end,
	}
end


local function network_config_status_topic()
	return { 'cap', 'network-config', 'main', 'status' }
end

local function network_config_apply_topic()
	return { 'cap', 'network-config', 'main', 'rpc', 'apply' }
end

local function network_state_status_topic()
	return { 'cap', 'network-state', 'main', 'status' }
end

local function network_state_watch_topic()
	return { 'cap', 'network-state', 'main', 'rpc', 'watch' }
end

local function retain_network_config_status_payload(conn, payload)
	return conn:retain(network_config_status_topic(), payload)
end

local function retain_network_state_status_payload(conn, payload)
	return conn:retain(network_state_status_topic(), payload)
end

local function retain_network_config_status(conn, status)
	return conn:retain(network_config_status_topic(), {
		schema = 'devicecode.cap.status/1',
		state = status,
		available = status == 'available' or status == 'running',
	})
end

local function bind_network_config_apply(scope, conn, calls, reply_fn)
	local ep = assert(conn:bind(network_config_apply_topic(), { queue_len = 8 }))
	local spawned, err = scope:spawn(function ()
		while true do
			local req = fibers.perform(ep:recv_op())
			if not req then return end
			local payload = req.payload or {}
			calls[#calls + 1] = payload
			local reply = reply_fn and reply_fn(req, payload) or {
				ok = true,
				reason = {
					ok = true,
					applied = true,
					changed = true,
					backend = 'test-cap',
					intent_rev = payload.intent and payload.intent.rev,
				},
			}
			req:reply(reply)
		end
	end)
	ok(spawned, err)
	return ep
end

local function bind_network_state_watch(scope, conn, calls, reply_fn)
	local ep = assert(conn:bind(network_state_watch_topic(), { queue_len = 8 }))
	local spawned, err = scope:spawn(function ()
		while true do
			local req = fibers.perform(ep:recv_op())
			if not req then return end
			local payload = req.payload or {}
			calls[#calls + 1] = payload
			local reply = reply_fn and reply_fn(req, payload) or {
				ok = true,
				reason = { ok = true, watching = true, backend = 'test-cap' },
			}
			req:reply(reply)
		end
	end)
	ok(spawned, err)
	return ep
end

local function start_service(scope, conn, params)
	local child = ok(scope:child())
	local spawned, err = child:spawn(function ()
		service.run(child, params)
	end)
	ok(spawned, err)
	return child
end

function tests.test_initial_config_starts_apply_and_publishes_running_state()
	fibers.run(function (scope)
		local b = busmod.new()
		local conn = b:connect()
		local reader = b:connect()
		local calls = {}

		retain_network_config_status(conn, 'available')

		local child = start_service(scope, conn, {
			conn = conn,
			config = cfg(),
			rev = 17,
			hal = success_hal(calls),
		})

		local view = reader:retained_view(topics.summary())
		local summary = probe.wait_versioned_until('net running summary',
			function () return view:version() end,
			function (seen) return view:changed_op(seen) end,
			function ()
				local msg = view:get(topics.summary())
				return msg and msg.payload and msg.payload.state == 'running' and msg.payload or nil
			end,
			{ timeout = 0.5 })
		eq(summary.service, 'net')
		eq(summary.state, 'running')
		eq(summary.ready, true)
		eq(summary.generation, 1)
		eq(summary.apply.state, 'applied')
		eq(summary.apply.last_applied_rev, 17)
		eq(summary.dependencies.network_config.status, 'available')
		eq(summary.counts.segments, 1)
		eq(#calls, 1)
		eq(calls[1].intent.rev, 17)
		eq(calls[1].opts.generation, 1)
		eq(calls[1].opts.apply_id, 1)

		local seg_msg = view:get(topics.segment('lan'))
		local seg = seg_msg and seg_msg.payload or probe.wait_retained_payload(reader, topics.segment('lan'), { timeout = 0.2 })
		eq(seg.kind, 'lan')
		view:close()

		child:cancel('test complete')
		fibers.perform(child:join_op())
	end)
end

function tests.test_config_waits_for_network_config_capability()
	fibers.run(function (scope)
		local b = busmod.new()
		local conn = b:connect()
		local reader = b:connect()

		local child = start_service(scope, conn, {
			conn = conn,
			config = cfg(),
			rev = 18,
			observe = false,
		})

		local view = reader:retained_view(topics.summary())
		local summary = probe.wait_versioned_until('net waiting for network-config capability',
			function () return view:version() end,
			function (seen) return view:changed_op(seen) end,
			function ()
				local msg = view:get(topics.summary())
				local payload = msg and msg.payload
				return payload and payload.state == 'waiting_for_hal' and payload or nil
			end,
			{ timeout = 0.5 })
		eq(summary.service, 'net')
		eq(summary.state, 'waiting_for_hal')
		eq(summary.ready, false)
		eq(summary.reason, 'network_config_unavailable')
		eq(summary.apply.state, 'waiting_for_hal')
		eq(summary.stats.apply_started, 0)
		ok(summary.dependencies and summary.dependencies.network_config, 'network_config dependency expected')
		eq(summary.dependencies.network_config.status, 'configured')
		eq(summary.dependencies.network_config.available, false)
		view:close()

		child:cancel('test complete')
		fibers.perform(child:join_op())
	end)
end

function tests.test_network_config_available_false_does_not_start_apply()
	fibers.run(function (scope)
		local b = busmod.new()
		local conn = b:connect()
		local reader = b:connect()
		local calls = {}

		local apply_ep = bind_network_config_apply(scope, conn, calls)
		retain_network_config_status_payload(conn, {
			schema = 'devicecode.cap.status/1',
			state = 'available',
			available = false,
		})

		local child = start_service(scope, conn, {
			conn = conn,
			config = cfg(),
			rev = 24,
			observe = false,
		})

		local view = reader:retained_view(topics.summary())
		local summary = probe.wait_versioned_until('net does not apply when network-config is not effectively available',
			function () return view:version() end,
			function (seen) return view:changed_op(seen) end,
			function ()
				local msg = view:get(topics.summary())
				local payload = msg and msg.payload
				return payload and payload.state == 'waiting_for_hal'
					and payload.stats.apply_started == 0
					and payload or nil
			end,
			{ timeout = 0.5 })
		eq(summary.reason, 'network_config_unavailable')
		eq(#calls, 0)
		fibers.perform(sleep.sleep_op(0.05))
		eq(#calls, 0)
		view:close()

		apply_ep:close()
		child:cancel('test complete')
		fibers.perform(child:join_op())
	end)
end

function tests.test_network_state_running_available_false_does_not_start_observer()
	fibers.run(function (scope)
		local b = busmod.new()
		local conn = b:connect()
		local reader = b:connect()
		local calls = {}

		local watch_ep = bind_network_state_watch(scope, conn, calls)
		retain_network_state_status_payload(conn, {
			schema = 'devicecode.cap.status/1',
			state = 'running',
			available = false,
		})

		local child = start_service(scope, conn, {
			conn = conn,
			observe = true,
		})

		local view = reader:retained_view(topics.summary())
		local summary = probe.wait_versioned_until('net records network-state status without starting observer',
			function () return view:version() end,
			function (seen) return view:changed_op(seen) end,
			function ()
				local msg = view:get(topics.summary())
				local payload = msg and msg.payload
				local dep = payload and payload.dependencies and payload.dependencies.network_state
				return dep and dep.status == 'running' and payload or nil
			end,
			{ timeout = 0.5 })
		eq(summary.dependencies.network_state.status, 'running')
		eq(#calls, 0)
		fibers.perform(sleep.sleep_op(0.05))
		eq(#calls, 0)
		view:close()

		watch_ep:close()
		child:cancel('test complete')
		fibers.perform(child:join_op())
	end)
end

function tests.test_network_config_available_starts_pending_apply()
	fibers.run(function (scope)
		local b = busmod.new()
		local conn = b:connect()
		local reader = b:connect()
		local calls = {}

		local child = start_service(scope, conn, {
			conn = conn,
			config = cfg(),
			rev = 21,
			observe = false,
		})

		local view = reader:retained_view(topics.summary())
		probe.wait_versioned_until('net pending apply before capability is available',
			function () return view:version() end,
			function (seen) return view:changed_op(seen) end,
			function ()
				local msg = view:get(topics.summary())
				local payload = msg and msg.payload
				return payload and payload.state == 'waiting_for_hal' and payload or nil
			end,
			{ timeout = 0.5 })

		local apply_ep = bind_network_config_apply(scope, conn, calls)
		retain_network_config_status(conn, 'available')

		local summary = probe.wait_versioned_until('net apply after network-config becomes available',
			function () return view:version() end,
			function (seen) return view:changed_op(seen) end,
			function ()
				local msg = view:get(topics.summary())
				local payload = msg and msg.payload
				return payload and payload.state == 'running' and payload.apply.state == 'applied' and payload or nil
			end,
			{ timeout = 0.5 })
		eq(#calls, 1)
		eq(calls[1].intent.rev, 21)
		eq(calls[1].opts.generation, 1)
		eq(calls[1].opts.apply_id, 1)
		eq(summary.apply.last_applied_rev, 21)
		eq(summary.dependencies.network_config.status, 'available')
		ok(summary.dependencies and summary.dependencies.network_config, 'network_config dependency expected')
		eq(summary.dependencies.network_config.available, true)
		view:close()

		apply_ep:close()
		child:cancel('test complete')
		fibers.perform(child:join_op())
	end)
end

function tests.test_newer_pending_config_wins_when_capability_arrives()
	fibers.run(function (scope)
		local b = busmod.new()
		local conn = b:connect()
		local writer = b:connect()
		local reader = b:connect()
		local calls = {}

		local child = start_service(scope, conn, { conn = conn, observe = false })
		local view = reader:retained_view(topics.summary())
		probe.wait_versioned_until('net ready to receive config',
			function () return view:version() end,
			function (seen) return view:changed_op(seen) end,
			function ()
				local msg = view:get(topics.summary())
				local payload = msg and msg.payload
				return payload and payload.state == 'waiting_for_config' and payload or nil
			end,
			{ timeout = 0.5 })

		writer:retain(topics.config(), { rev = 31, data = cfg() })
		local c2 = cfg()
		c2.segments.lan.vlan = 20
		writer:retain(topics.config(), { rev = 32, data = c2 })

		probe.wait_versioned_until('net records newest pending config before capability is available',
			function () return view:version() end,
			function (seen) return view:changed_op(seen) end,
			function ()
				local msg = view:get(topics.summary())
				local payload = msg and msg.payload
				return payload and payload.state == 'waiting_for_hal'
					and payload.config and payload.config.rev == 32
					and payload.stats.apply_started == 0
					and payload or nil
			end,
			{ timeout = 0.5 })

		local apply_ep = bind_network_config_apply(scope, conn, calls)
		retain_network_config_status(conn, 'available')

		local summary = probe.wait_versioned_until('net applies newest pending config',
			function () return view:version() end,
			function (seen) return view:changed_op(seen) end,
			function ()
				local msg = view:get(topics.summary())
				local payload = msg and msg.payload
				return payload and payload.state == 'running' and payload.apply.state == 'applied' and payload or nil
			end,
			{ timeout = 0.5 })
		eq(#calls, 1)
		eq(calls[1].intent.rev, 32)
		eq(calls[1].opts.generation, 2)
		eq(summary.generation, 2)
		eq(summary.apply.last_applied_rev, 32)
		view:close()

		apply_ep:close()
		child:cancel('test complete')
		fibers.perform(child:join_op())
	end)
end

function tests.test_no_route_apply_returns_to_pending_not_degraded()
	fibers.run(function (scope)
		local b = busmod.new()
		local conn = b:connect()
		local reader = b:connect()
		local calls = {}

		retain_network_config_status(conn, 'available')
		local child = start_service(scope, conn, {
			conn = conn,
			config = cfg(),
			rev = 22,
			observe = false,
		})

		local view = reader:retained_view(topics.summary())
		local pending = probe.wait_versioned_until('net returns no_route apply to pending',
			function () return view:version() end,
			function (seen) return view:changed_op(seen) end,
			function ()
				local msg = view:get(topics.summary())
				local payload = msg and msg.payload
				return payload and payload.state == 'waiting_for_hal'
					and payload.apply.state == 'waiting_for_hal'
					and payload.stats.apply_started == 1
					and payload or nil
			end,
			{ timeout = 0.5 })
		eq(pending.ready, false)
		eq(pending.reason, 'network_config_unavailable')

		local apply_ep = bind_network_config_apply(scope, conn, calls)
		retain_network_config_status(conn, 'available')

		local summary = probe.wait_versioned_until('net retries pending apply after route returns',
			function () return view:version() end,
			function (seen) return view:changed_op(seen) end,
			function ()
				local msg = view:get(topics.summary())
				local payload = msg and msg.payload
				return payload and payload.state == 'running' and payload.apply.state == 'applied' and payload or nil
			end,
			{ timeout = 0.5 })
		eq(#calls, 1)
		eq(calls[1].intent.rev, 22)
		eq(summary.apply.last_applied_rev, 22)
		view:close()

		apply_ep:close()
		child:cancel('test complete')
		fibers.perform(child:join_op())
	end)
end

function tests.test_network_config_backend_failure_still_degrades()
	fibers.run(function (scope)
		local b = busmod.new()
		local conn = b:connect()
		local reader = b:connect()
		local calls = {}

		local apply_ep = bind_network_config_apply(scope, conn, calls, function ()
			return {
				ok = false,
				code = 500,
				reason = { code = 'backend_failed', err = 'nft apply failed' },
			}
		end)
		retain_network_config_status(conn, 'available')

		local child = start_service(scope, conn, {
			conn = conn,
			config = cfg(),
			rev = 23,
			observe = false,
		})

		local view = reader:retained_view(topics.summary())
		local summary = probe.wait_versioned_until('net degrades on real network-config failure',
			function () return view:version() end,
			function (seen) return view:changed_op(seen) end,
			function ()
				local msg = view:get(topics.summary())
				local payload = msg and msg.payload
				return payload and payload.state == 'degraded' and payload or nil
			end,
			{ timeout = 0.5 })
		eq(summary.ready, false)
		eq(summary.apply.state, 'failed')
		contains(summary.reason, 'nft apply failed')
		eq(#calls, 1)
		view:close()

		apply_ep:close()
		child:cancel('test complete')
		fibers.perform(child:join_op())
	end)
end

function tests.test_observed_state_updates_model_and_drift()
	fibers.run(function (scope)
		local mailbox = require 'fibers.mailbox'
		local b = busmod.new()
		local conn = b:connect()
		local reader = b:connect()
		local calls = {}
		local obs_tx, obs_rx = mailbox.new(8, { full = 'drop_oldest' })

		local hal = success_hal(calls)
		hal.open_observed_subscription = function () return obs_rx end
		hal.start_observation_op = function () return op.always({ ok = true, backend = 'test', watching = true }) end

		retain_network_config_status(conn, 'available')
		retain_network_state_status_payload(conn, {
			schema = 'devicecode.cap.status/1',
			state = 'running',
			available = true,
		})

		local child = start_service(scope, conn, {
			conn = conn,
			config = cfg(),
			rev = 19,
			hal = hal,
		})

		local observed = {
			schema = 'devicecode.net.observation/1',
			kind = 'snapshot_done',
			source = 'test',
			subject = 'network',
			observed = {
				schema = 'devicecode.net.observed/1',
				interfaces = {
					lan_bridge = { id = 'lan_bridge', enabled = true },
				},
				segments = {
					lan = { id = 'lan', interfaces = { 'lan_bridge' } },
				},
			},
		}
		obs_tx:send({ payload = observed })

		local view = reader:retained_view(topics.summary())
		local summary = probe.wait_versioned_until('net observed summary',
			function () return view:version() end,
			function (seen) return view:changed_op(seen) end,
			function ()
				local msg = view:get(topics.summary())
				return msg and msg.payload and msg.payload.stats and msg.payload.stats.observations == 1 and msg.payload or nil
			end,
			{ timeout = 0.5 })
		eq(summary.dependencies.network_state.status, 'running')
			eq(summary.dependencies.network_state.available, true)
		eq(summary.observed.last_subject, 'network')
		eq(summary.drift.converged, true)
		view:close()

		child:cancel('test complete')
		fibers.perform(child:join_op())
	end)
end


function tests.test_wan_members_trigger_speedtests_and_live_weights()
	fibers.run(function (scope)
		local mailbox = require 'fibers.mailbox'
		local b = busmod.new()
		local conn = b:connect()
		local reader = b:connect()
		local calls = {}
		local speedtests = {}
		local weights = {}
		local obs_tx, obs_rx = mailbox.new(8, { full = 'drop_oldest' })
		local hal = success_hal(calls)
		hal.speedtest_op = function (_, req)
			speedtests[#speedtests + 1] = req
			local mbps = req.interface == 'wan_a' and 80 or 20
			return op.always({ ok = true, interface = req.interface, device = req.device, peak_mbps = mbps, data_mib = 1, duration_s = 0.1 })
		end
		hal.apply_live_weights_op = function (_, req)
			weights[#weights + 1] = req
			return op.always({ ok = true, changed = true, applied = true })
		end
		hal.open_observed_subscription = function () return obs_rx end
		hal.start_observation_op = function () return op.always({ ok = true, backend = 'test', watching = true }) end

		local c = cfg()
		c.wan = {
			load_balancing = { policy = 'balanced', speedtests = true },
			members = {
				wan_a = { interface = 'wan_a', mwan_metric = 1, weight = 1 },
				wan_b = { interface = 'wan_b', mwan_metric = 1, weight = 1 },
			},
		}
		c.interfaces.wan_a = { kind = 'ethernet', role = 'wan', segment = 'wan', endpoint = { ifname = 'eth1' }, addressing = { ipv4 = { mode = 'dhcp' } } }
		c.interfaces.wan_b = { kind = 'cellular', role = 'wan', segment = 'wan', endpoint = { ifname = 'wwan1' }, addressing = { ipv4 = { mode = 'dhcp' } } }
		c.segments.wan = { kind = 'wan', firewall = { zone = 'wan' } }

		retain_network_config_status(conn, 'available')
		retain_network_state_status_payload(conn, {
			schema = 'devicecode.cap.status/1',
			state = 'running',
			available = true,
		})

		local child = start_service(scope, conn, { conn = conn, config = c, rev = 20, hal = hal })
		obs_tx:send({ payload = {
			schema = 'devicecode.net.observation/1',
			kind = 'snapshot_done',
			source = 'test',
			subject = 'network',
			observed = {
				multiwan = {
					interfaces_by_semantic = {
						wan_a = { interface = 'wan_a', state = 'online', online = true, usable = true },
						wan_b = { interface = 'wan_b', state = 'online', online = true, usable = true },
					},
				},
			},
		} })

		local view = reader:retained_view(topics.domain('wan_runtime'))
		local runtime = probe.wait_versioned_until('net wan runtime weights',
			function () return view:version() end,
			function (seen) return view:changed_op(seen) end,
			function ()
				local msg = view:get(topics.domain('wan_runtime'))
				local payload = msg and msg.payload
				return payload and payload.live_weights and payload.live_weights.state == 'applied' and payload or nil
			end,
			{ timeout = 1.0 })
		ok(#speedtests >= 2, 'expected every WAN member to be speed-tested')
		ok(#weights >= 1, 'expected live weight apply')
		local members = runtime.live_weights.members
		ok(type(members) == 'table' and #members >= 2, 'members expected')
		view:close()
		child:cancel('test complete')
		fibers.perform(child:join_op())
	end)
end


return tests
