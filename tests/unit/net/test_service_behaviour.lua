-- tests/unit/net/test_service_behaviour.lua

local fibers = require 'fibers'
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
		eq(summary.hal.network_config, 'available')
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

function tests.test_missing_hal_marks_apply_failed_not_running()
	fibers.run(function (scope)
		local b = busmod.new()
		local conn = b:connect()
		local reader = b:connect()

		local child = start_service(scope, conn, {
			conn = conn,
			config = cfg(),
			rev = 18,
		})

		local view = reader:retained_view(topics.summary())
		local summary = probe.wait_versioned_until('net degraded summary',
			function () return view:version() end,
			function (seen) return view:changed_op(seen) end,
			function ()
				local msg = view:get(topics.summary())
				return msg and msg.payload and msg.payload.state == 'degraded' and msg.payload or nil
			end,
			{ timeout = 0.5 })
		eq(summary.service, 'net')
		eq(summary.state, 'degraded')
		eq(summary.ready, false)
		eq(summary.apply.state, 'failed')
		contains(summary.reason, 'network-config HAL capability not configured')
		view:close()

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
		eq(summary.hal.network_state, 'available')
		eq(summary.observed.last_subject, 'network')
		eq(summary.drift.converged, true)
		view:close()

		child:cancel('test complete')
		fibers.perform(child:join_op())
	end)
end


function tests.test_gsm_uplink_triggers_speedtest_and_live_weights()
	fibers.run(function (scope)
		local b = busmod.new()
		local conn = b:connect()
		local reader = b:connect()
		local calls = {}
		local speedtests = {}
		local weights = {}
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

		local c = cfg()
		c.wan = {
			policy = 'weighted_failover',
			load_balancing = { speedtests = true },
			members = {
				gsm_a = { interface = 'wan_a', metric = 1, weight = 1 },
				gsm_b = { interface = 'wan_b', metric = 1, weight = 1 },
			},
		}
		c.interfaces.wan_a = { kind = 'cellular', role = 'wan', segment = 'wan', endpoint = { ifname = 'wwan0' }, addressing = { ipv4 = { mode = 'dhcp' } } }
		c.interfaces.wan_b = { kind = 'cellular', role = 'wan', segment = 'wan', endpoint = { ifname = 'wwan1' }, addressing = { ipv4 = { mode = 'dhcp' } } }
		c.segments.wan = { kind = 'wan', firewall = { zone = 'wan' } }

		local child = start_service(scope, conn, { conn = conn, config = c, rev = 20, hal = hal })
		probe.wait_retained_payload(reader, topics.summary(), { timeout = 0.5 })

		conn:retain({ 'state', 'gsm', 'modem', 'gsm_a', 'uplink' }, {
			modem = 'gsm_a', connected = true, openwrt_interface = 'wan_a', interface = 'wan_a', device = 'wwan0',
		})
		conn:retain({ 'state', 'gsm', 'modem', 'gsm_b', 'uplink' }, {
			modem = 'gsm_b', connected = true, openwrt_interface = 'wan_b', interface = 'wan_b', device = 'wwan1',
		})

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
		ok(#speedtests >= 2, 'expected both GSM uplinks to be speed-tested')
		ok(#weights >= 1, 'expected live weight apply')
		local members = runtime.live_weights.members
		ok(type(members) == 'table' and #members >= 2, 'members expected')
		view:close()
		child:cancel('test complete')
		fibers.perform(child:join_op())
	end)
end

return tests
