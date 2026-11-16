-- tests/unit/wifi/service_spec.lua
--
-- Wi-Fi service client tracking: sessions, hostnames and num_sta follow the
-- radio's retained 'clients' state and reach the metrics topics.

local busmod = require 'bus'
local fibers = require 'fibers'
local sleep = require 'fibers.sleep'
local runfibers = require 'tests.support.run_virtual_fibers'
local gen = require 'services.wifi.gen'
local wifi = require 'services.wifi'

local T = {}

local SALT = 'test-salt'

local function eq(a, b, msg)
	if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end

local svc = { obs_log = function () end }

-- Collects every message on obs/v1/wifi/metric/<stat>.
local function collect_metrics(scope, conn)
	local out = {}
	local sub = conn:subscribe({ 'obs', 'v1', 'wifi', 'metric', '+' }, { queue_len = 256 })
	scope:spawn(function ()
		while true do
			local msg = sub:recv()
			if not msg then return end
			out[#out + 1] = { stat = msg.topic[5], value = msg.payload.value, ns = table.concat(msg.payload.namespace, '.') }
		end
	end)
	return out
end

local function find(metrics, stat, ns_part)
	local out = {}
	for _, m in ipairs(metrics) do
		if m.stat == stat and (not ns_part or m.ns:find(ns_part, 1, true)) then out[#out + 1] = m end
	end
	return out
end

local function retain_clients(conn, radio_id, interfaces, hostnames)
	conn:retain({ 'cap', 'radio', radio_id, 'state', 'clients' }, { interfaces = interfaces, hostnames = hostnames or {} })
end

local function start_loop(scope, conn, sessions)
	local loop_scope = assert(scope:child())
	loop_scope:spawn(function ()
		wifi._test.radio_stats_loop(conn, 'radio0', { band = '5g' }, SALT, svc, sessions)
	end)
	return loop_scope
end

function T.sessions_and_hostnames_follow_clients_and_survive_a_loop_restart()
	runfibers.run_auto(function (scope)
		local b = busmod.new()
		local conn = b:connect()
		local metrics = collect_metrics(scope, b:connect())
		local sessions = {}
		local uid_aa = gen.userid('aa', SALT)

		retain_clients(conn, 'radio0', { radio0_i0 = { 'aa', 'bb' } }, { aa = 'phone' })
		local loop = start_loop(scope, conn, sessions)
		sleep.sleep(0.02)

		eq(#find(metrics, 'session_start'), 2, 'a session for each connected client')
		local hostname = find(metrics, 'hostname')
		eq(#hostname, 1)
		eq(hostname[1].value, 'phone')
		assert(hostname[1].ns:find('wifi.clients.' .. uid_aa .. '.sessions.', 1, true) == 1, hostname[1].ns)
		eq(find(metrics, 'num_sta', 'rd5.num_sta')[1].value, 2, 'radio num_sta')

		-- Reconfigure restarts the loop; sessions continue rather than restart.
		loop:cancel('reconfigure')
		fibers.perform(loop:join_op())
		loop = start_loop(scope, conn, sessions)
		sleep.sleep(0.02)
		eq(#find(metrics, 'session_start'), 2, 'no new sessions after a restart')
		eq(#find(metrics, 'hostname'), 1, 'hostname not resent for the same session')

		-- aa leaves.
		retain_clients(conn, 'radio0', { radio0_i0 = { 'bb' } })
		sleep.sleep(0.02)
		local ends = find(metrics, 'session_end')
		eq(#ends, 1)
		assert(ends[1].ns:find('wifi.clients.' .. uid_aa .. '.sessions.', 1, true) == 1, ends[1].ns)
		local num = find(metrics, 'num_sta', 'rd5.num_sta')
		eq(num[#num].value, 1, 'radio num_sta after aa left')

		loop:cancel('test done')
	end, { timeout = 1 })
end

function T.interface_counts_are_independent_and_radio_total_counts_each_mac_once()
	runfibers.run_auto(function (scope)
		local b = busmod.new()
		local conn = b:connect()
		local metrics = collect_metrics(scope, b:connect())
		local totals = {}

		retain_clients(conn, 'radio0', { radio0_i0 = { 'aa' }, radio0_i1 = { 'aa', 'bb' } })
		local loop_scope = assert(scope:child())
		loop_scope:spawn(function ()
			wifi._test.radio_stats_loop(conn, 'radio0', { band = '5g' }, SALT, svc, {},
				function (total) totals[#totals + 1] = total end)
		end)
		sleep.sleep(0.02)

		local i0 = find(metrics, 'num_sta', 'rd5.0.num_sta')
		local i1 = find(metrics, 'num_sta', 'rd5.1.num_sta')
		eq(i0[#i0].value, 1, 'aa counted on radio0_i0')
		eq(i1[#i1].value, 2, 'aa and bb counted on radio0_i1')
		eq(totals[#totals], 2, 'radio total counts aa once')
		loop_scope:cancel('test done')
	end, { timeout = 1 })
end

function T.removed_radio_drops_out_of_global_num_sta_and_ends_its_sessions()
	runfibers.run_auto(function (scope)
		local b = busmod.new()
		local conn = b:connect()
		local metrics = collect_metrics(scope, b:connect())
		local ctx = {
			conn = conn,
			radio_scopes = {},
			radio_sessions = { radio0 = { aa = { uid = 'u1', sid = 's1' } } },
			radio_sta = { radio0 = 1, radio1 = 2 },
		}

		wifi._test.remove_radio(ctx, 'radio0')
		sleep.sleep(0.01)

		local global = find(metrics, 'num_sta', 'wifi.num_sta')
		eq(global[#global].value, 2, 'only radio1 counted')
		eq(#find(metrics, 'session_end', 'wifi.clients.u1.sessions.s1'), 1, 'radio0 session ended')
		eq(ctx.radio_sessions.radio0, nil)
	end, { timeout = 1 })
end

function T.report_period_falls_back_to_the_service_setting()
	local calls = {}
	local radio_cap = {
		id = 'radio0',
		call_control = function (_, method, args)
			calls[#calls + 1] = { method = method, args = args }
			return { ok = true }, ''
		end,
	}
	wifi._test.apply_radio_config(radio_cap, { name = 'radio0', band = '5g' }, {}, nil, nil, svc, 10)
	local period
	for _, c in ipairs(calls) do
		if c.method == 'set_report_period' then period = c.args.period end
	end
	eq(period, 10, 'service-level report_period used when the radio has none')
end

return T
