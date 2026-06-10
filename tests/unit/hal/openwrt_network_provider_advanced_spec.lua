-- tests/unit/hal/openwrt_network_provider_advanced_spec.lua

local fibers = require 'fibers'
local provider_loader = require 'services.hal.backends.network.provider'
local names = require 'services.hal.backends.network.providers.openwrt.names'

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
-A mwan3_iface_in_wanb -i eth2 -m mark --mark 0x0/0x3f00 -m comment --comment wanb -j MARK --set-xmark 0x300/0x3f00
-A mwan3_iface_in_wanc -i eth3 -m mark --mark 0x0/0x3f00 -m comment --comment wanc -j MARK --set-xmark 0x500/0x3f00
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
			wan_a = { kind = 'cellular', role = 'wan', segment = 'wan', endpoint = { ifname = 'wwan0' }, addressing = { ipv4 = { mode = 'dhcp' } } },
			wan_b = { kind = 'cellular', role = 'wan', segment = 'wan', endpoint = { ifname = 'wwan1' }, addressing = { ipv4 = { mode = 'dhcp' } } },
		},
		firewall = { zones = { lan = {}, guest = {}, wan = { masq = true } }, policies = { guest_to_wan = { from = 'guest', to = 'wan' } } },
		routing = {}, dns = {}, dhcp = {},
		wan = {
			enabled = true,
			load_balancing = { speedtests = true, policy = 'balanced' },
			rules = { https = { family = 'ipv4', proto = 'tcp', dest_port = '443', policy = 'balanced', sticky = true } },
			health = { track_ip = { '1.1.1.1', '8.8.8.8' }, reliability = 1 },
			members = {
				gsm_a = { interface = 'wan_a', mwan_metric = 1, weight = 1 },
				gsm_b = { interface = 'wan_b', mwan_metric = 1, weight = 1 },
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


function tests.test_mwan_uplinks_get_distinct_network_route_metrics_and_default_routes()
	fibers.run(function()
		local provider = ok(provider_loader.new({ provider = 'openwrt', allow_fake_uci = true }, {}))
		local plan = fibers.perform(provider:plan_op({ intent = intent() }))
		eq(plan.ok, true)
		local names = plan.openwrt_names or {}
		local seen = {}
		local metrics = {}
		for _, ch in ipairs(plan.plan and plan.plan.raw_changes and plan.plan.raw_changes.network or {}) do
			if ch.op == 'set' and ch.config == 'network' and ch.option == 'metric' then
				metrics[ch.section] = tostring(ch.value)
			elseif ch.op == 'set' and ch.config == 'network' and ch.option == 'defaultroute' and ch.value == '0' then
				fail('mwan uplink must not emit defaultroute 0 on ' .. tostring(ch.section))
			end
		end
		local ctx = require('services.hal.backends.network.providers.openwrt.names').allocate(intent())
		for _, semantic in ipairs({ 'wan_a', 'wan_b' }) do
			local sec = ctx:iface(semantic)
			ok(metrics[sec], 'route metric expected on ' .. semantic)
			if seen[metrics[sec]] then fail('duplicate route metric ' .. tostring(metrics[sec])) end
			seen[metrics[sec]] = true
		end
		provider:terminate('test complete')
	end)
end


function tests.test_mwan_rules_flow_from_config_to_mwan3_uci()
	fibers.run(function()
		local provider = ok(provider_loader.new({ provider = 'openwrt', allow_fake_uci = true }, {}))
		local plan = fibers.perform(provider:plan_op({ intent = intent() }))
		eq(plan.ok, true)
		local ctx = require('services.hal.backends.network.providers.openwrt.names').allocate(intent())
		local rule = ctx:mwan_rule('https')
		local seen = {}
		for _, ch in ipairs(plan.plan and plan.plan.raw_changes and plan.plan.raw_changes.mwan3 or {}) do
			if ch.config == 'mwan3' and ch.section == rule then seen[ch.option] = tostring(ch.value) end
		end
		eq(seen.proto, 'tcp', 'https sticky proto')
		eq(seen.dest_port, '443', 'https sticky dest port')
		eq(seen.family, 'ipv4', 'https sticky family')
		eq(seen.sticky, '1', 'https sticky flag')
		eq(seen.use_policy, ctx:mwan_policy('balanced'), 'https sticky policy')
		provider:terminate('test complete')
	end)
end

function tests.test_apply_uses_shaper_and_schedules_structural_mwan3_activation()
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
		ok(#shaper_cmds > 0, 'tc shaper commands expected')
		provider:terminate('test complete')
	end)
end

function tests.test_live_weight_update_uses_iptables_restore_and_persists_without_restart()
	fibers.run(function()
		local restores, restart_cmds = {}, {}
		local provider = ok(provider_loader.new({
			provider = 'openwrt',
			allow_fake_uci = true,
			debounce_s = 0.01,
			run_cmd = function(argv) restart_cmds[#restart_cmds + 1] = argv_s(argv); return true, nil end,
			mwan_run_cmd_capture = function(argv)
				eq(argv_s(argv), 'iptables-save -t mangle')
				return true, MWAN_RULESET, nil
			end,
			mwan_run_restore = function(content) restores[#restores + 1] = content; return true, nil end,
			mwan_run_cmd = function(_argv) fail('live weights must not use sequential iptables commands') end,
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
		eq(#restores, 1, 'one iptables-restore payload expected')
		contains(restores[1], '*mangle')
		contains(restores[1], '-F mwan3_policy_balanced')
		contains(restores[1], '--probability 0.70000000000')
		contains(restores[1], '--set-xmark 0x100/0x3f00')
		contains(restores[1], '--comment "wanb 30 30"')
		contains(restores[1], '--set-xmark 0x300/0x3f00')
		contains(restores[1], 'COMMIT')
		if table.concat(restart_cmds, '\n'):find('mwan3', 1, true) then fail('live weights must not restart mwan3') end
		provider:terminate('test complete')
	end)
end

function tests.test_live_weight_three_member_conditional_probabilities()
	local mwan3 = require 'services.hal.backends.network.providers.openwrt.mwan3'
	local restore, err = mwan3.build_live_weight_restore({
		policy = 'balanced',
		members = {
			{ interface = 'wan', weight = 50 },
			{ interface = 'wanb', weight = 30 },
			{ interface = 'wanc', weight = 20 },
		},
	}, MWAN_RULESET)
	ok(restore, err)
	contains(restore, '--probability 0.50000000000') -- 50 / 100
	contains(restore, '--set-xmark 0x100/0x3f00')
	contains(restore, '--probability 0.60000000000') -- 30 / remaining 50
	contains(restore, '--set-xmark 0x300/0x3f00')
	contains(restore, '--comment "wanc 20 20"')
	contains(restore, '--set-xmark 0x500/0x3f00')
end

function tests.test_live_weight_negative_cases()
	local mwan3 = require 'services.hal.backends.network.providers.openwrt.mwan3'
	local restore, err = mwan3.build_live_weight_restore({ policy = 'balanced', members = { { interface = 'missing', weight = 1 } } }, MWAN_RULESET)
	eq(restore, nil)
	contains(err, 'no MWAN3 firewall mark found')

	restore, err = mwan3.build_live_weight_restore({ policy = 'absent', members = { { interface = 'wan', weight = 1 } } }, MWAN_RULESET)
	eq(restore, nil)
	contains(err, 'MWAN3 policy chain not found')

	restore, err = mwan3.build_live_weight_restore({ policy = 'balanced', members = { { interface = 'wan', weight = 1, enabled = false } } }, MWAN_RULESET)
	eq(restore, nil)
	contains(err, 'no enabled positive-weight')

	restore, err = mwan3.build_live_weight_restore({ policy = 'balanced', members = { { interface = 'wan', weight = 1 } } }, MWAN_RULESET)
	ok(restore, err)
	if restore:find('%-%-probability', 1, true) then fail('single-member policy must not include random probability') end
	contains(restore, '--comment "wan 1 1"')
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

function tests.test_speedtest_translates_semantic_device_to_linux_counter_device()
	fibers.run(function()
		local seen_req
		local provider = ok(provider_loader.new({
			provider = 'openwrt',
			allow_fake_uci = true,
			speedtest_run_cmd = function()
				return true, '42', nil
			end,
		}, {}))
		provider._last_name_ctx = ok(names.allocate({
			segments = { wan = { kind = 'wan', vlan = 10 } },
			interfaces = { wan = { kind = 'ethernet', role = 'wan', segment = 'wan' } },
			wan = { members = { wan = { interface = 'wan' } } },
		}))
		provider.speedtest_run_cmd = function(_argv)
			return true, '42', nil
		end
		local speedtest = require 'services.hal.backends.network.providers.openwrt.speedtest'
		local original = speedtest.run_op
		speedtest.run_op = function(req, opts)
			seen_req = req
			return original(req, opts)
		end
		local result = fibers.perform(provider:speedtest_op({ interface = 'wan' }))
		speedtest.run_op = original
		eq(result.ok, true)
		eq(seen_req.interface, 'wan')
		eq(seen_req.device, 'vl-wan')
		provider:terminate('test complete')
	end)
end


function tests.test_segment_trunk_realises_segments_without_cfg_net_interfaces()
	fibers.run(function()
		local provider = ok(provider_loader.new({
			provider = 'openwrt',
			allow_fake_uci = true,
			platform = { segment_trunk = { ifname = 'eth0', protected = true } },
		}, {}))
		local plan = fibers.perform(provider:plan_op({ intent = {
			schema = 'devicecode.net.intent/1',
			rev = 1,
			segments = {
				mgmt = { kind = 'system', protected = true, vlan = { id = 10 }, addressing = { ipv4 = { mode = 'static', cidr = '192.168.8.1/24' } } },
				guest = { kind = 'guest', vlan = { id = 101 }, addressing = { ipv4 = { mode = 'static', cidr = '192.168.101.1/24' } } },
			},
			interfaces = {},
			firewall = { zones = { mgmt = {}, guest = {} }, policies = {} },
			routing = {}, dns = {}, dhcp = {}, wan = {}, shaping = {}, vpn = {}, diagnostics = {},
		} }))
		eq(plan.ok, true)
		ok(plan.plan.packages.network.sections >= 5, 'segment trunk should create globals plus interface/device sections')
		provider:terminate('test complete')
	end)
end


local function read_project_file(rel)
	local candidates = { rel, '../' .. rel }
	for i = 1, #candidates do
		local f = io.open(candidates[i], 'rb')
		if f then local data = f:read('*a'); f:close(); return data end
	end
	return nil, 'unable to read ' .. rel
end

function tests.test_bigbox_clean_config_plans_dns_rules_routes_and_segment_shaping()
	fibers.run(function()
		local cjson = require 'cjson.safe'
		local cfg_mod = require 'services.net.config'
		local text = ok(read_project_file('src/configs/bigbox-v1-cm-2.json'))
		local doc = ok(cjson.decode(text), 'bigbox config must decode')
		local intent = ok(cfg_mod.normalise(doc.net, { generation = 1 }))
		local shaper_cmds = {}
		local provider = ok(provider_loader.new({
			provider = 'openwrt',
			allow_fake_uci = true,
			platform = { segment_trunk = { ifname = 'eth0' } },
			shaper_run_cmd = function(argv) shaper_cmds[#shaper_cmds + 1] = table.concat(argv, ' '); return true, nil end,
		}, {}))
		local plan = fibers.perform(provider:plan_op({ intent = intent }))
		eq(plan.ok, true)
		ok(plan.plan.packages.dhcp.changes > 0, 'dns/dhcp changes expected')
		ok(plan.plan.packages.firewall.changes > 0, 'firewall changes expected')
		ok(plan.plan.packages.network.changes > 0, 'network changes expected')
		local result = fibers.perform(provider:apply_op({ intent = intent }))
		eq(result.ok, true)
		ok(result.shaping and result.shaping.ok == true, 'segment-profile shaping should be applied')
		ok(#shaper_cmds > 0, 'segment shaping should emit tc commands')
		provider:terminate('test complete')
	end)
end



function tests.test_bigbox_starlink_admin_route_is_explicit_host_route()
	fibers.run(function()
		local cjson = require 'cjson.safe'
		local cfg_mod = require 'services.net.config'
		local text = ok(read_project_file('src/configs/bigbox-v1-cm-2.json'))
		local doc = ok(cjson.decode(text), 'bigbox config must decode')
		local intent = ok(cfg_mod.normalise(doc.net, { generation = 1 }))
		local provider = ok(provider_loader.new({
			provider = 'openwrt',
			allow_fake_uci = true,
			platform = { segment_trunk = { ifname = 'eth0' } },
		}, {}))
		local plan = fibers.perform(provider:plan_op({ intent = intent }))
		eq(plan.ok, true)
		local route = {}
		for _, ch in ipairs(plan.plan and plan.plan.raw_changes and plan.plan.raw_changes.network or {}) do
			if ch.config == 'network' and ch.section == 'route_starlink_admin' then route[ch.option] = tostring(ch.value) end
		end
		eq(route.interface, 'wan', 'Starlink route interface')
		eq(route.target, '192.168.100.1', 'Starlink route target')
		eq(route.netmask, '255.255.255.255', 'Starlink host route netmask')
		provider:terminate('test complete')
	end)
end

function tests.test_mwan3_builder_uses_distinct_section_names_for_same_interface_and_member_ids()
	local names = require 'services.hal.backends.network.providers.openwrt.names'
	local mwan3 = require 'services.hal.backends.network.providers.openwrt.mwan3'
	local intent_doc = {
		wan = {
			enabled = true,
			health = { track_ip = { '1.1.1.1' } },
			members = {
				wan = { interface = 'wan', mwan_metric = 1, weight = 1 },
				modem_primary = { interface = 'modem_primary', mwan_metric = 1, weight = 1 },
				modem_secondary = { interface = 'modem_secondary', mwan_metric = 1, weight = 1 },
			},
		},
	}
	local ctx = ok(names.allocate(intent_doc))
	local changes = ok(mwan3.build_changes(intent_doc, ctx))
	local sections = {}
	local policy = ctx:mwan_policy('balanced')
	for _, ch in ipairs(changes) do
		if ch.op == 'set' and ch.config == 'mwan3' and ch.value == nil then
			if sections[ch.section] then fail('duplicate mwan3 section name generated: ' .. tostring(ch.section)) end
			sections[ch.section] = ch.option
		elseif ch.config == 'mwan3' and ch.section == policy and ch.option == 'use_member' and ch.op == 'delete' then
			fail('full mwan3 package replacement should not delete use_member before it exists')
		end
	end
	ok(sections[ctx:mwan_iface('wan')], 'wan interface section expected')
	ok(sections[ctx:mwan_member('wan')], 'wan member section expected')
	eq(ctx:mwan_iface('wan') == ctx:mwan_member('wan'), false, 'interface/member names must differ')

	local live_changes = ok(mwan3.build_changes(intent_doc, ctx, { clear_policy_members = true }))
	local deleted_use_member_at = nil
	local first_added_use_member_at = nil
	for i, ch in ipairs(live_changes) do
		if ch.config == 'mwan3' and ch.section == policy and ch.option == 'use_member' then
			if ch.op == 'delete' then deleted_use_member_at = deleted_use_member_at or i end
			if ch.op == 'add_list' then first_added_use_member_at = first_added_use_member_at or i end
		end
	end
	ok(deleted_use_member_at, 'live policy use_member list should be cleared before replacement')
	ok(first_added_use_member_at and deleted_use_member_at < first_added_use_member_at, 'live policy use_member clear must precede add_list entries')
end

return tests
