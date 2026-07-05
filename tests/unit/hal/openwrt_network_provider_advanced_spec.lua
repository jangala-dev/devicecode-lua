-- tests/unit/hal/openwrt_network_provider_advanced_spec.lua

local fibers = require 'fibers'
local provider_loader = require 'services.hal.backends.network.provider'
local names = require 'services.hal.backends.network.providers.openwrt.names'
local net_config = require 'services.net.config'

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


function tests.test_read_counters_reads_requested_device_stats_and_reports_missing()
	fibers.run(function()
		local calls = {}
		local values = {
			['br-adm'] = { rx_bytes = 12345, tx_packets = 77 },
		}
		local provider = ok(provider_loader.new({
			provider = 'openwrt',
			counter_reader = function(device, stat)
				calls[#calls + 1] = { device = device, stat = stat }
				local v = values[device] and values[device][stat]
				if v == nil then return nil, 'missing counter' end
				return v, nil
			end,
		}, {}))
		local result = fibers.perform(provider:read_counters_op({
			interfaces = { 'adm' },
			devices = { adm = 'br-adm' },
			stats = { 'rx_bytes', 'tx_packets', 'rx_errors' },
		}))
		eq(result.ok, true)
		eq(result.counters.adm.device, 'br-adm')
		eq(result.counters.adm.statistics.rx_bytes, 12345)
		eq(result.counters.adm.statistics.tx_packets, 77)
		eq(result.errors.adm.device, 'br-adm')
		contains(result.errors.adm.rx_errors, 'missing counter')
		eq(#calls, 3)
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

function tests.test_segment_profile_shaping_targets_segment_data_device()
	fibers.run(function()
		local shaper_cmds = {}
		local segment_intent = {
			schema = 'devicecode.net.intent/1',
			rev = 1,
			segments = {
				jan = {
					kind = 'user',
					vlan = { id = 32 },
					addressing = { ipv4 = { mode = 'static', cidr = '172.28.32.1/30' } },
					shaping = { profile = 'restricted' },
				},
				direct = {
					kind = 'user',
					l2 = { mode = 'direct' },
					vlan = { id = 40 },
					addressing = { ipv4 = { mode = 'static', cidr = '172.28.40.1/30' } },
					shaping = { profile = 'restricted' },
				},
			},
			interfaces = {},
			dns = {}, dhcp = {}, firewall = { zones = {}, policies = {}, rules = {} },
			routing = {}, wan = {}, vpn = {}, diagnostics = {},
			shaping = {
				enabled = true,
				profiles = {
					restricted = {
						egress = {
							enabled = true,
							match = 'dst',
							pool_rate = '10mbit',
							pool_ceil = '10mbit',
							host_rate = '1mbit',
							host_ceil = '2mbit',
							all_hosts = true,
						},
					},
				},
			},
		}
		local provider = ok(provider_loader.new({
			provider = 'openwrt',
			allow_fake_uci = true,
			platform = { segment_trunk = { ifname = 'eth0' } },
			shaper_run_cmd = function(argv) shaper_cmds[#shaper_cmds + 1] = table.concat(argv, ' '); return true, nil end,
		}, {}))
		local result = fibers.perform(provider:apply_op({ intent = segment_intent }))
		eq(result.ok, true)
		ok(result.shaping and result.shaping.ok == true, 'segment-profile shaping should be applied')
		eq(result.shaping.links.jan.iface, 'br-jan', 'bridged segment shaping should target the bridge data device')
		eq(result.shaping.links.direct.iface, 'vl-direct', 'direct segment shaping should target the VLAN data device')
		ok(#shaper_cmds > 0, 'segment-profile shaping should emit tc commands')
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
		ok(result.shaping.links and result.shaping.links.jan, 'jan shaping link should be reported')
		eq(result.shaping.links.jan.iface, 'br-jan', 'jan shaping should target the bridge data device')
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
	local use_members = {}
	for _, ch in ipairs(changes) do
		if ch.op == 'set' and ch.config == 'mwan3' and ch.value == nil then
			if sections[ch.section] then fail('duplicate mwan3 section name generated: ' .. tostring(ch.section)) end
			sections[ch.section] = ch.option
		elseif ch.config == 'mwan3' and ch.section == policy and ch.option == 'use_member' then
			if ch.op == 'delete' then fail('full mwan3 package replacement should not delete use_member before it exists') end
			if ch.op == 'add_list' then use_members[tostring(ch.value)] = (use_members[tostring(ch.value)] or 0) + 1 end
		end
	end
	ok(sections[ctx:mwan_iface('wan')], 'wan interface section expected')
	ok(sections[ctx:mwan_member('wan')], 'wan member section expected')
	eq(ctx:mwan_iface('wan') == ctx:mwan_member('wan'), false, 'interface/member names must differ')
	for _, mid in ipairs({ 'wan', 'modem_primary', 'modem_secondary' }) do
		eq(use_members[ctx:mwan_member(mid)], 1, 'use_member should contain each intended member exactly once')
	end

	local weight_changes = ok(mwan3.build_weight_only_changes({ members = {
		{ id = 'wan', interface = 'wan', metric = 2, weight = 70 },
		{ id = 'modem_primary', interface = 'modem_primary', metric = 1, weight = 30 },
	} }, ctx))
	local seen = {}
	for _, ch in ipairs(weight_changes) do
		eq(ch.config, 'mwan3')
		eq(ch.op, 'set')
		ok(ch.option == 'weight' or ch.option == 'metric', 'weight-only persistence must only set member weight/metric')
		ok(ch.section == ctx:mwan_member('wan') or ch.section == ctx:mwan_member('modem_primary'), 'weight-only persistence must target member sections')
		seen[ch.section .. '.' .. ch.option] = ch.value
	end
	eq(seen[ctx:mwan_member('wan') .. '.weight'], 70)
	eq(seen[ctx:mwan_member('wan') .. '.metric'], 2)
	eq(seen[ctx:mwan_member('modem_primary') .. '.weight'], 30)
	eq(seen[ctx:mwan_member('modem_primary') .. '.metric'], 1)

	fibers.run(function()
		local op = require 'fibers.op'
		local submitted
		local mgr = {
			submit_op = function(_, record)
				submitted = record
				return op.always(true, nil, true)
			end,
		}
		local ok_persist, err, admitted = fibers.perform(mwan3.persist_weights_op(mgr, { members = {
			{ id = 'wan', interface = 'wan', metric = 3, weight = 44 },
		} }, ctx))
		eq(ok_persist, true, tostring(err))
		eq(admitted, true)
		eq(submitted.config, 'mwan3')
		eq(#submitted.restart_cmds, 0, 'weight persistence must not restart mwan3')
		for _, ch in ipairs(submitted.changes or {}) do
			eq(ch.op, 'set')
			ok(ch.option == 'weight' or ch.option == 'metric', 'persist_weights_op must only set weight/metric')
		end
	end)
end


local function find_change(changes, fields)
	for _, ch in ipairs(changes or {}) do
		local ok = true
		for k, v in pairs(fields or {}) do
			if ch[k] ~= v then ok = false; break end
		end
		if ok then return ch end
	end
	return nil
end

function tests.test_bigbox_net_intent_still_renders_openwrt_segment_trunk_independent_of_wired_assembly()
	fibers.run(function()
		local intent, ierr = net_config.normalise({
			schema = net_config.SCHEMA,
			version = 1,
			segments = {
				adm = { kind = 'system', protected = true, vlan = { id = 8 }, addressing = { ipv4 = { mode = 'static', cidr = '172.28.8.1/24' } }, firewall = { zone = 'lan' } },
				jan = { kind = 'user', vlan = { id = 32 }, addressing = { ipv4 = { mode = 'static', cidr = '172.28.32.1/24' } }, firewall = { zone = 'lan_rst' } },
				int = { kind = 'system', protected = true, vlan = { id = 100 }, addressing = { ipv4 = { mode = 'static', cidr = '172.28.100.1/24' } }, firewall = { zone = 'lan' } },
				wan = { kind = 'wan', vlan = { id = 4 }, addressing = { ipv4 = { mode = 'dhcp', peerdns = false } }, firewall = { zone = 'wan' } },
			},
			interfaces = {},
			dns = {}, dhcp = {}, firewall = { zones = { lan = {}, lan_rst = {}, wan = { masq = true } }, policies = {}, rules = {} },
			routing = { routes = { starlink_admin = { kind = 'host', target = '192.168.100.1', interface = 'wan' } } },
			wan = { enabled = true, members = { wan = { interface = 'wan', weight = 1, mwan_metric = 1 } } },
			shaping = {}, vpn = {}, diagnostics = {},
		}, { rev = 1 })
		ok(intent, ierr)
		local provider = ok(provider_loader.new({
			provider = 'openwrt',
			allow_fake_uci = true,
			platform = { segment_trunk = { ifname = 'eth0', protected = true } },
		}, {}))
		local plan = fibers.perform(provider:plan_op({ intent = intent }))
		eq(plan.ok, true)
		local changes = plan.plan and plan.plan.raw_changes and plan.plan.raw_changes.network or {}

		for _, rec in ipairs({
			{ id = 'adm', vid = 8, vlan = 'vl-adm', bridge = 'br-adm', proto = 'static', ipaddr = '172.28.8.1' },
			{ id = 'jan', vid = 32, vlan = 'vl-jan', bridge = 'br-jan', proto = 'static', ipaddr = '172.28.32.1' },
			{ id = 'int', vid = 100, vlan = 'vl-int', bridge = 'br-int', proto = 'static', ipaddr = '172.28.100.1' },
		}) do
			local vlan_sec = 'dev_vlan_' .. rec.id
			local bridge_sec = 'dev_bridge_' .. rec.id
			ok(find_change(changes, { section = vlan_sec, option = 'ifname', value = 'eth0' }), rec.id .. ' VLAN should use eth0 trunk')
			ok(find_change(changes, { section = vlan_sec, option = 'vid', value = rec.vid }), rec.id .. ' VLAN id should render')
			ok(find_change(changes, { section = vlan_sec, option = 'name', value = rec.vlan }), rec.id .. ' VLAN device should render')
			ok(find_change(changes, { section = bridge_sec, option = 'name', value = rec.bridge }), rec.id .. ' bridge should render')
			ok(find_change(changes, { section = rec.id, option = 'device', value = rec.bridge }), rec.id .. ' interface should use bridge')
			ok(find_change(changes, { section = rec.id, option = 'proto', value = rec.proto }), rec.id .. ' proto should render')
			ok(find_change(changes, { section = rec.id, option = 'ipaddr', value = rec.ipaddr }), rec.id .. ' IP address should render')
		end

		ok(find_change(changes, { section = 'dev_vlan_wan', option = 'ifname', value = 'eth0' }), 'wan VLAN should use eth0 trunk')
		ok(find_change(changes, { section = 'dev_vlan_wan', option = 'vid', value = 4 }), 'wan VLAN id should render')
		ok(find_change(changes, { section = 'wan', option = 'device', value = 'vl-wan' }), 'wan interface should use WAN VLAN device')
		ok(find_change(changes, { section = 'wan', option = 'proto', value = 'dhcp' }), 'wan interface should remain DHCP')
		ok(find_change(changes, { section = 'wan', option = 'peerdns', value = '0' }), 'wan peerdns false should render')
		ok(find_change(changes, { section = 'route_starlink_admin', option = 'interface', value = 'wan' }), 'Starlink route should remain on semantic wan interface')
		ok(find_change(changes, { section = 'route_starlink_admin', option = 'target', value = '192.168.100.1' }), 'Starlink route target should render')
		provider:terminate('test complete')
	end)
end

function tests.test_semantic_segment_profile_compiles_budgeted_peak_layout()
	fibers.run(function()
		local batch_text = {}
		local segment_intent = {
			schema = 'devicecode.net.intent/1', rev = 1,
			segments = {
				jan = { kind = 'user', vlan = { id = 32 }, addressing = { ipv4 = { mode = 'static', cidr = '172.28.32.1/30' } }, shaping = { profile = 'restricted' } },
			},
			interfaces = {}, dns = {}, dhcp = {}, firewall = { zones = {}, policies = {}, rules = {} }, routing = {}, wan = {}, vpn = {}, diagnostics = {},
			shaping = {
				enabled = true,
				profiles = {
					restricted = {
						segment = { download = { limit = '40mbit' }, upload = { limit = '10mbit' } },
						host_default = {
							mode = 'budgeted_peak',
							download = { sustained_rate = '2mbit', peak_rate = '8mbit', burst_budget = '500k' },
							upload = { sustained_rate = '1500kbit', peak_rate = '6mbit', burst_budget = '225k' },
						},
					},
				},
			},
		}
		local provider = ok(provider_loader.new({
			provider = 'openwrt', allow_fake_uci = true, platform = { segment_trunk = { ifname = 'eth0' } },
			shaper_run_cmd = function(argv)
				if argv[1] == 'tc' and argv[2] == '-batch' and type(argv[3]) == 'string' then
					local f = io.open(argv[3], 'rb')
					if f then batch_text[#batch_text + 1] = f:read('*a') or ''; f:close() end
				end
				return true, '', nil
			end,
		}, {}))
		local result = fibers.perform(provider:apply_op({ intent = segment_intent }))
		eq(result.ok, true)
		eq(result.shaping.links.jan.iface, 'br-jan')
		local all = table.concat(batch_text, '\n')
		contains(all, 'qdisc add dev br-jan root handle 1: htb default 1', 'aggregate budgeted_peak should keep unmatched root traffic on root default class')
		contains(all, 'class replace dev br-jan parent 20: classid 20:1002 htb rate 2mbit burst 500k ceil 2mbit cburst 500k', 'download host budget should be under aggregate with sustained ceil')
		contains(all, 'qdisc add dev br-jan parent 20:1002 handle 1002: htb default 1', 'download host budget should own a peak HTB qdisc')
		contains(all, 'class replace dev br-jan parent 1002: classid 1002:1 htb rate 8mbit ceil 8mbit', 'download host peak class should cap burst spend rate')
		contains(all, 'filter add dev br-jan parent 20: protocol ip prio 99 handle 1: u32 divisor 256', 'aggregate budgeted_peak should classify hosts under the segment aggregate qdisc')
		contains(all, 'qdisc add dev br-jan parent 1:20 handle 20: htb default 100', 'aggregate budgeted_peak should install an inner HTB under the segment aggregate')
		provider:terminate('test complete')
	end)
end


function tests.test_inline_segment_shaping_compiles_without_profile()
	fibers.run(function()
		local batch_text = {}
		local segment_intent = {
			schema = 'devicecode.net.intent/1', rev = 1,
			segments = {
				jan = {
					kind = 'user', vlan = { id = 32 }, addressing = { ipv4 = { mode = 'static', cidr = '172.28.32.1/30' } },
					shaping = {
						download = { limit = '40mbit' },
						upload = { limit = '10mbit' },
						host_default = {
							mode = 'budgeted_peak',
							download = { sustained_rate = '2mbit', peak_rate = '8mbit', burst_budget = '500k' },
							upload = { sustained_rate = '1500kbit', peak_rate = '6mbit', burst_budget = '225k' },
						},
					},
				},
			},
			interfaces = {}, dns = {}, dhcp = {}, firewall = { zones = {}, policies = {}, rules = {} }, routing = {}, wan = {}, vpn = {}, diagnostics = {},
			shaping = { enabled = true, profiles = {} },
		}
		local provider = ok(provider_loader.new({
			provider = 'openwrt', allow_fake_uci = true, platform = { segment_trunk = { ifname = 'eth0' } },
			shaper_run_cmd = function(argv)
				if argv[1] == 'tc' and argv[2] == '-batch' and type(argv[3]) == 'string' then
					local f = io.open(argv[3], 'rb')
					if f then batch_text[#batch_text + 1] = f:read('*a') or ''; f:close() end
				end
				return true, '', nil
			end,
		}, {}))
		local result = fibers.perform(provider:apply_op({ intent = segment_intent }))
		eq(result.ok, true)
		eq(result.shaping.links.jan.profile, nil)
		eq(result.shaping.links.jan.iface, 'br-jan')
		local all = table.concat(batch_text, '\n')
		contains(all, 'class replace dev br-jan parent 20: classid 20:1002 htb rate 2mbit burst 500k ceil 2mbit cburst 500k', 'inline segment host budget should compile')
		contains(all, 'class replace dev br-jan parent 1002: classid 1002:1 htb rate 8mbit ceil 8mbit', 'inline segment peak class should compile')
		provider:terminate('test complete')
	end)
end

function tests.test_wan_member_shaping_renders_router_exemption_marks_and_wan_mark_link()
	fibers.run(function()
		local restores = {}
		local cmds = {}
		local i = intent()
		i.wan.members.wired = {
			interface = 'wan_a', mwan_metric = 1, weight = 1,
			shaping = { download = { limit = '80mbit' }, upload = { limit = '20mbit' } },
		}
		local provider = ok(provider_loader.new({
			provider = 'openwrt', allow_fake_uci = true,
			shaper_run_cmd = function(argv) cmds[#cmds + 1] = table.concat(argv, ' '); return true, '', nil end,
			shaper_run_restore = function(payload) restores[#restores + 1] = payload; return true, nil, '' end,
		}, {}))
		local result = fibers.perform(provider:apply_op({ intent = i }))
		eq(result.ok, true)
		ok(result.shaping.links.backhaul_wired, 'backhaul shaping link should be reported')
		eq(result.shaping.links.backhaul_wired.kind, 'wan_mark')
		eq(#restores, 1, 'one shaping mangle restore expected')
		local r = restores[1]
		contains(r, ':DEVICECODE_SHAPING_OUTPUT', 'router-output chain expected')
		contains(r, ':DEVICECODE_SHAPING_FORWARD', 'forwarded-client chain expected')
		contains(r, '-A DEVICECODE_SHAPING_OUTPUT -o wwan0', 'router traffic should be marked on the WAN device')
		contains(r, 'devicecode-shaping router exempt', 'router exemption comment expected')
		contains(r, 'CONNMARK --save-mark --mask 0x00f00000', 'router/client marks should be saved to conntrack')
		contains(r, '-A DEVICECODE_SHAPING_FORWARD -o wwan0', 'forwarded traffic should be marked client')
		local all_cmds = table.concat(cmds, '\n')
		contains(all_cmds, 'tc class replace dev wwan0 parent 1:1 classid 1:20 htb rate 20mbit ceil 20mbit', 'WAN upload client class should use upload limit')
		contains(all_cmds, 'tc filter add dev wwan0 parent ffff: protocol ip prio 1 u32 match u32 0 0 action ctinfo cpmark 0x00f00000 action mirred egress redirect dev ifb_wwan0', 'WAN download should restore connmark before IFB redirect')
		contains(all_cmds, 'tc class replace dev ifb_wwan0 parent 1:1 classid 1:20 htb rate 80mbit ceil 80mbit', 'WAN download client class should use download limit')
		provider:terminate('test complete')
	end)
end


function tests.test_shaping_mark_namespace_does_not_overlap_mwan_default_mask()
	local marks = require 'services.hal.backends.network.providers.openwrt.shaping_marks'
	local spec, err = marks.validate_marks({ marks = marks.default_marks() }, '0x3f00')
	ok(spec, tostring(err))
	eq(spec.mask, '0x00f00000')
	local bad, berr = marks.validate_marks({ marks = { mask = '0x00003f00', control = '0x00000100', client = '0x00000200' } }, '0x3f00')
	eq(bad, nil)
	contains(tostring(berr), 'overlaps MWAN mask')
end


return tests
