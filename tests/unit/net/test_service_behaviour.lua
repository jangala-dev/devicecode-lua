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

return tests
