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



function tests.test_backhaul_publishes_configured_gsm_members_even_when_unrealised()
	fibers.run(function (scope)
		local b = busmod.new()
		local conn = b:connect()
		local reader = b:connect()
		local calls = {}

		local c = cfg()
		c.segments.wan = { kind = 'wan', vlan = { id = 4 }, firewall = { zone = 'wan' }, addressing = { ipv4 = { mode = 'dhcp' } } }
		c.wan = {
			members = {
				wan = { interface = 'wan', weight = 1 },
				modem_primary = { interface = 'modem_primary', source = { kind = 'gsm-uplink', id = 'primary' }, weight = 1 },
				modem_secondary = { interface = 'modem_secondary', source = { kind = 'gsm-uplink', id = 'secondary' }, weight = 1 },
			},
		}

		retain_network_config_status(conn, 'available')
		local child = start_service(scope, conn, {
			conn = conn,
			config = c,
			rev = 32,
			hal = success_hal(calls),
			observe = false,
		})

		local summary_view = reader:retained_view(topics.summary())
		probe.wait_versioned_until('net running summary with configured gsm wan members',
			function () return summary_view:version() end,
			function (seen) return summary_view:changed_op(seen) end,
			function ()
				local msg = summary_view:get(topics.summary())
				return msg and msg.payload and msg.payload.state == 'running' and msg.payload or nil
			end,
			{ timeout = 0.5 })

		local wan_domain = probe.wait_retained_payload(reader, topics.domain('wan'), { timeout = 0.2 })
		ok(wan_domain.configured_members and wan_domain.configured_members.wan, 'configured WAN catalogue expected')
		ok(wan_domain.configured_members.modem_primary, 'configured primary modem member expected in NET model')
		ok(wan_domain.realised_members and wan_domain.realised_members.wan, 'realised wired WAN member expected')
		eq(wan_domain.realised_members.modem_primary, nil)
		eq(wan_domain.members, nil)

		local backhaul = probe.wait_retained_payload(reader, topics.domain('backhaul'), { timeout = 0.2 })
		ok(backhaul.uplinks.wan, 'wired WAN member expected')
		ok(backhaul.uplinks.modem_primary, 'configured primary modem WAN member expected')
		ok(backhaul.uplinks.modem_secondary, 'configured secondary modem WAN member expected')
		eq(backhaul.uplinks.modem_primary.state, 'unknown')
		eq(backhaul.uplinks.modem_primary.observed, false)
		eq(backhaul.uplinks.modem_primary.source.kind, 'gsm-uplink')
		eq(backhaul.uplinks.modem_primary.source.id, 'primary')
		-- HAL apply still receives only the realised member set: without GSM ifnames,
		-- modem interfaces are not written to OpenWrt.
		eq(calls[1].intent.wan.members.modem_primary, nil)
		eq(calls[1].intent.wan.members.modem_secondary, nil)

		summary_view:close()
		child:cancel('test complete')
		fibers.perform(child:join_op())
	end)
end

function tests.test_counter_metrics_publish_generic_topics_with_member_namespaces()
	fibers.run(function (scope)
		local b = busmod.new()
		local conn = b:connect()
		local sub_conn = b:connect()
		local calls = {}
		local counter_calls = {}
		local sub = sub_conn:subscribe({ 'obs', 'v1', 'net', 'metric', '+' }, { queue_len = 256, full = 'drop_oldest' })

		local hal = success_hal(calls)
		hal.read_counters_op = function (_, req)
			counter_calls[#counter_calls + 1] = req
			local counters = {}
			local bases = { adm = 1000, jan = 2000, wan = 3000, modem_primary = 4000, modem_secondary = 5000 }
			for _, iface in ipairs(req.interfaces or {}) do
				local stats = {}
				local base = bases[iface] or 0
				for i, stat in ipairs(req.stats or {}) do stats[stat] = base + i end
				counters[iface] = { statistics = stats }
			end
			return op.always({ ok = true, backend = 'test', counters = counters })
		end

		local c = cfg()
		c.segments.adm = { kind = 'lan', addressing = { ipv4 = { mode = 'static', cidr = '172.28.8.1/24' } } }
		c.segments.jan = { kind = 'lan', addressing = { ipv4 = { mode = 'static', cidr = '172.28.32.1/24' } } }
		c.segments.wan = { kind = 'wan', addressing = { ipv4 = { mode = 'dhcp' } }, dhcp = { enabled = false } }
		c.wan = {
			members = {
				modem_primary = { interface = 'modem_primary', source = { kind = 'gsm-uplink', id = 'primary' } },
				modem_secondary = { interface = 'modem_secondary', source = { kind = 'gsm-uplink', id = 'secondary' } },
			},
		}

		conn:retain(topics.gsm_uplink('primary'), { connected = true, available = true, linux = { ifname = 'wwan0' } })
		conn:retain(topics.gsm_uplink('secondary'), { connected = true, available = true, linux = { ifname = 'wwan1' } })
		retain_network_config_status(conn, 'available')
		local child = start_service(scope, conn, {
			conn = conn,
			config = c,
			rev = 31,
			hal = hal,
			observe = false,
			counter_poll_interval_s = 0.05,
		})

		local view = sub_conn:retained_view(topics.summary())
		probe.wait_versioned_until('net counter metrics running summary',
			function () return view:version() end,
			function (seen) return view:changed_op(seen) end,
			function ()
				local msg = view:get(topics.summary())
				return msg and msg.payload and msg.payload.state == 'running' and msg.payload or nil
			end,
			{ timeout = 0.5 })
		view:close()

		local expected = {
			['net.adm.rx_bytes'] = 1001,
			['net.jan.tx_errors'] = 2008,
			['net.wan.rx_packets'] = 3002,
			['net.modem_primary.rx_dropped'] = 4003,
			['net.modem_secondary.tx_packets'] = 5006,
		}
		local seen = {}
		local deadline = fibers.now() + 2.0
		while fibers.now() < deadline do
			local which, msg = fibers.perform(op.named_choice({
				msg = sub:recv_op(),
				timeout = sleep.sleep_op(0.05),
			}))
			if which == 'msg' and msg and msg.payload then
				local payload = msg.payload
				local key = table.concat(payload.namespace or {}, '.')
				if expected[key] ~= nil then
					local fields = 0
					for _ in pairs(payload) do fields = fields + 1 end
					eq(fields, 2, 'metric payload must only contain value and namespace')
					eq(msg.topic[5], payload.namespace[3], 'generic metric topic should match stat class')
					seen[key] = payload.value
				end
				local complete = true
				for key in pairs(expected) do if seen[key] == nil then complete = false end end
				if complete then break end
			end
		end
		local requested = counter_calls[1] and table.concat(counter_calls[1].interfaces or {}, ',') or 'none'
		for key, value in pairs(expected) do eq(seen[key], value, 'missing counter metric ' .. key .. ' requested=' .. requested) end
		ok(#counter_calls >= 1, 'counter poll expected')

		sub:unsubscribe()
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


function tests.test_wan_speedtests_wait_for_multiwan_observation()
	fibers.run(function (scope)
		local mailbox = require 'fibers.mailbox'
		local b = busmod.new()
		local conn = b:connect()
		local reader = b:connect()
		local calls = {}
		local speedtests = {}
		local obs_tx, obs_rx = mailbox.new(8, { full = 'drop_oldest' })
		local hal = success_hal(calls)
		hal.speedtest_op = function (_, req)
			speedtests[#speedtests + 1] = req
			return op.always({ ok = true, interface = req.interface, peak_mbps = 10 })
		end
		hal.open_observed_subscription = function () return obs_rx end
		hal.start_observation_op = function () return op.always({ ok = true, backend = 'test', watching = true }) end

		local c = cfg()
		c.wan = {
			load_balancing = { policy = 'balanced', speedtests = true },
			members = {
				wan_a = { interface = 'wan_a', mwan_metric = 1, weight = 1 },
			},
		}
		c.interfaces.wan_a = { kind = 'ethernet', role = 'wan', segment = 'wan', endpoint = { ifname = 'eth1' }, addressing = { ipv4 = { mode = 'dhcp' } } }
		c.segments.wan = { kind = 'wan', firewall = { zone = 'wan' } }

		retain_network_config_status(conn, 'available')
		retain_network_state_status_payload(conn, {
			schema = 'devicecode.cap.status/1',
			state = 'running',
			available = true,
		})
		local skipped_sub = reader:subscribe({ 'obs', 'v1', 'net', 'event', 'speedtest_skipped' }, { queue_len = 8, full = 'drop_oldest' })

		local child = start_service(scope, conn, { conn = conn, config = c, rev = 21, hal = hal })
		local which, msg = fibers.perform(op.named_choice({
			event = skipped_sub:recv_op(),
			timeout = sleep.sleep_op(0.5),
		}))
		ok(which == 'event' and msg and msg.payload, 'expected speedtest skip event')
		eq(msg.payload.reason, 'waiting_for_observation')
		eq(msg.payload.backhaul_status, 'missing')
		eq(#speedtests, 0, 'speedtest should wait for observed multiwan status')

		obs_tx:send({ payload = {
			schema = 'devicecode.net.observation/1',
			kind = 'snapshot_done',
			source = 'test',
			subject = 'network',
			observed = {
				multiwan = {
					interfaces_by_semantic = {
						wan_a = { interface = 'wan_a', state = 'online', online = true, usable = true },
					},
				},
				live = { interfaces = {
					wan_a = { ipv4 = { { address = '203.0.113.10' } } },
				} },
			},
		} })

		ok(probe.wait_until(function () return #speedtests == 1 end, { timeout = 0.5 }), 'speedtest should start after observation')
		skipped_sub:unsubscribe()
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
		local metric_sub = reader:subscribe({ 'obs', 'v1', 'net', 'metric', 'speedtest' }, { queue_len = 8, full = 'drop_oldest' })

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
				live = { interfaces = {
					wan_a = { ipv4 = { { address = '203.0.113.10' } } },
					wan_b = { ipv4 = { { address = '10.1.2.3' } } },
				} },
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
		local seen = {}
		for _ = 1, 2 do
			local which, msg = fibers.perform(op.named_choice({
				metric = metric_sub:recv_op(),
				timeout = sleep.sleep_op(0.2),
			}))
			ok(which == 'metric' and msg and msg.payload, 'expected speedtest metric')
			local ns = msg.payload.namespace
			ok(type(ns) == 'table', 'speedtest metric namespace expected')
			eq(ns[1], 'net')
			eq(ns[3], 'speedtest')
			seen[ns[2]] = msg.payload.value
		end
		eq(seen.wan_a, 80)
		eq(seen.wan_b, 20)
		metric_sub:unsubscribe()
		view:close()
		child:cancel('test complete')
		fibers.perform(child:join_op())
	end)
end


return tests
