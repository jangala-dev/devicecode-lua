-- tests/unit/hal/openwrt_network_provider_advanced_spec.lua

local fibers = require 'fibers'
local provider_loader = require 'services.hal.backends.network.provider'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function ok(v, msg) if not v then fail(msg) end return v end
local function eq(a, b, msg) if a ~= b then fail((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end end
local function contains(s, needle, msg) if type(s) ~= 'string' or not s:find(needle, 1, true) then fail(msg or ('expected ' .. tostring(s) .. ' to contain ' .. tostring(needle))) end end


local MWAN_RULESET = [[
*mangle
:mwan3_iface_in_wan - [0:0]
:mwan3_iface_in_wanb - [0:0]
:mwan3_iface_in_wanc - [0:0]
:mwan3_policy_balanced - [0:0]
-A mwan3_iface_in_wan -i eth1 -m mark --mark 0x0/0x3f00 -m comment --comment wan -j MARK --set-xmark 0x100/0x3f00
-A mwan3_iface_in_wanb -i eth3 -m mark --mark 0x0/0x3f00 -m comment --comment wanb -j MARK --set-xmark 0x300/0x3f00
-A mwan3_iface_in_wanc -i eth4 -m mark --mark 0x0/0x3f00 -m comment --comment wanc -j MARK --set-xmark 0x500/0x3f00
-A mwan3_policy_balanced -m mark --mark 0x0/0x3f00 -m statistic --mode random --probability 0.50000000000 -m comment --comment "wanb 3 6" -j MARK --set-xmark 0x300/0x3f00
-A mwan3_policy_balanced -m mark --mark 0x0/0x3f00 -m comment --comment "wan 3 3" -j MARK --set-xmark 0x100/0x3f00
COMMIT
]]

local function argv_s(argv)
	return table.concat(argv or {}, ' ')
end

local function intent()
	return {
		schema = 'devicecode.net.intent/1',
		rev = 200,
		segments = {
			lan = { kind = 'lan', vlan = { id = 10 }, addressing = { ipv4 = { mode = 'static', cidr = '192.168.10.1/24' } }, dhcp = { enabled = true }, firewall = { zone = 'lan' } },
			guest = { kind = 'guest', vlan = 30, firewall = { zone = 'guest' } },
			wan = { kind = 'wan', firewall = { zone = 'wan' } },
		},
		interfaces = {
			lan = { kind = 'bridge', role = 'lan', segment = 'lan', members = { 'eth0' }, addressing = { ipv4 = { mode = 'static', cidr = '192.168.10.1/24' } } },
			wan_a = { kind = 'cellular', role = 'wan', segment = 'wan', endpoint = { ifname = 'wwan0' }, addressing = { ipv4 = { mode = 'dhcp', metric = 10 } } },
			wan_b = { kind = 'cellular', role = 'wan', segment = 'wan', endpoint = { ifname = 'wwan1' }, addressing = { ipv4 = { mode = 'dhcp', metric = 20 } } },
		},
		firewall = { zones = { lan = {}, guest = {}, wan = { masq = true } }, policies = { guest_to_wan = { from = 'guest', to = 'wan' } } },
		routing = {}, dns = {}, dhcp = {},
		wan = {
			enabled = true,
			policy = 'weighted_failover',
			load_balancing = { speedtests = true, policy = 'balanced' },
			health = { track_ip = { '1.1.1.1', '8.8.8.8' }, reliability = 1 },
			members = {
				gsm_a = { interface = 'wan_a', metric = 1, weight = 1 },
				gsm_b = { interface = 'wan_b', metric = 1, weight = 1 },
			},
		},
		shaping = {
			enabled = true,
			links = {
				wan_a = { iface = 'wwan0', egress = { enabled = true, host_rate = '2mbit', hosts = { ['192.168.10.2'] = { rate = '1mbit' } } } },
			},
		},
		vpn = {}, diagnostics = {},
	}
end

function tests.test_plan_reports_vlan_mwan3_and_shaping_domains()
	fibers.run(function()
		local provider = ok(provider_loader.new({ provider = 'openwrt', allow_fake_uci = true }, {}))
		local plan = fibers.perform(provider:plan_op({ intent = intent() }))
		eq(plan.ok, true)
		eq(plan.plan.domains.vlan.status, 'implemented')
		eq(plan.plan.domains.multiwan.status, 'implemented')
		eq(plan.plan.domains.shaping.status, 'implemented')
		ok(plan.plan.packages.mwan3.changes > 0, 'mwan3 should have UCI changes')
		provider:terminate('test complete')
	end)
end

function tests.test_apply_uses_shaper_and_writes_mwan3_without_restart()
	fibers.run(function(scope)
		local restart_cmds = {}
		local shaper_cmds = {}
		local provider = ok(provider_loader.new({
			provider = 'openwrt',
			allow_fake_uci = true,
			debounce_s = 0.01,
			run_cmd = function(argv) restart_cmds[#restart_cmds + 1] = table.concat(argv, ' '); return true, nil end,
			shaper_run_cmd = function(argv) shaper_cmds[#shaper_cmds + 1] = table.concat(argv, ' '); return true, nil end,
		}, {}))
		local result = fibers.perform(provider:apply_op({ intent = intent() }))
		eq(result.ok, true)
		ok(result.multiwan and result.multiwan.enabled == true, 'multiwan plan expected')
		ok(result.shaping and result.shaping.ok == true, 'shaping result expected')
		local all_restarts = table.concat(restart_cmds, '\n')
		if all_restarts:find('mwan3', 1, true) then fail('mwan3 must not be restarted by structural apply') end
		ok(#shaper_cmds > 0, 'tc shaper commands expected')
		provider:terminate('test complete')
	end)
end

function tests.test_live_weight_update_rewrites_mwan_policy_chain_and_persists_without_restart()
	fibers.run(function()
		local commands, restart_cmds = {}, {}
		local provider = ok(provider_loader.new({
			provider = 'openwrt',
			allow_fake_uci = true,
			debounce_s = 0.01,
			run_cmd = function(argv) restart_cmds[#restart_cmds + 1] = argv_s(argv); return true, nil end,
			mwan_run_cmd_capture = function(argv)
				eq(argv_s(argv), 'iptables-save -t mangle')
				return true, MWAN_RULESET, nil
			end,
			mwan_run_cmd = function(argv) commands[#commands + 1] = argv; return true, nil end,
		}, {}))
		local result = fibers.perform(provider:apply_live_weights_op({
			policy = 'balanced',
			members = {
				{ interface = 'wan', metric = 1, weight = 70 },
				{ interface = 'wanb', metric = 1, weight = 30 },
			},
			persist = true,
		}))
		eq(result.ok, true)
		eq(result.persisted, true)
		eq(#commands, 3, 'flush plus two append commands expected')
		eq(argv_s(commands[1]), 'iptables -t mangle -F mwan3_policy_balanced')
		contains(argv_s(commands[2]), '--probability 0.70000000000')
		contains(argv_s(commands[2]), '--set-xmark 0x100/0x3f00')
		contains(argv_s(commands[3]), '--comment wanb 30 30')
		contains(argv_s(commands[3]), '--set-xmark 0x300/0x3f00')
		if table.concat(restart_cmds, '\n'):find('mwan3', 1, true) then fail('live weights must not restart mwan3') end
		provider:terminate('test complete')
	end)
end

function tests.test_live_weight_three_member_conditional_probabilities()
	local mwan3 = require 'services.hal.backends.network.providers.openwrt.mwan3'
	local commands, err = mwan3.build_live_weight_commands({
		policy = 'balanced',
		members = {
			{ interface = 'wan', weight = 50 },
			{ interface = 'wanb', weight = 30 },
			{ interface = 'wanc', weight = 20 },
		},
	}, MWAN_RULESET)
	ok(commands, err)
	eq(#commands, 4, 'flush plus three append commands expected')
	contains(argv_s(commands[2]), '--probability 0.50000000000') -- 50 / 100
	contains(argv_s(commands[2]), '--set-xmark 0x100/0x3f00')
	contains(argv_s(commands[3]), '--probability 0.60000000000') -- 30 / remaining 50
	contains(argv_s(commands[3]), '--set-xmark 0x300/0x3f00')
	if argv_s(commands[4]):find('--probability', 1, true) then fail('last member should be fall-through') end
	contains(argv_s(commands[4]), '--set-xmark 0x500/0x3f00')
end

function tests.test_speedtest_uses_mwan3_use_boundary()
	fibers.run(function()
		local argv_seen
		local provider = ok(provider_loader.new({
			provider = 'openwrt',
			allow_fake_uci = true,
			speedtest_run_cmd = function(argv)
				argv_seen = argv
				return true, '42', nil
			end,
		}, {}))
		local result = fibers.perform(provider:speedtest_op({ interface = 'wan_a', device = 'wwan0' }))
		eq(result.ok, true)
		eq(result.peak_mbps, 42)
		eq(argv_seen[1], 'mwan3')
		eq(argv_seen[2], 'use')
		eq(argv_seen[3], 'wan_a')
		provider:terminate('test complete')
	end)
end

return tests
