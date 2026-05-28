-- tests/unit/hal/openwrt_names_spec.lua

local names = require 'services.hal.backends.network.providers.openwrt.names'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function ok(v, msg) if not v then fail(msg) end return v end
local function eq(a, b, msg) if a ~= b then fail((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end end

local function starts(s, p, msg)
	if type(s) ~= 'string' or s:sub(1, #p) ~= p then fail(msg or ('expected ' .. tostring(s) .. ' to start with ' .. tostring(p))) end
end

function tests.test_generated_names_are_bounded_and_readable()
	local ctx = ok(names.allocate({
		segments = {
			['administration-network-with-a-very-long-user-visible-name'] = { kind = 'system', firewall = { zone = 'restricted-admin-firewall-zone' } },
			['123-invalid-prefix-and-extremely-long'] = { kind = 'lan' },
		},
		interfaces = {
			['cellular-primary-uplink-with-long-name'] = {},
		},
		firewall = { zones = { ['restricted-admin-firewall-zone'] = {} } },
		wan = { members = { ['cellular-primary-uplink-with-long-name'] = { interface = 'cellular-primary-uplink-with-long-name' } } },
	}))
	local lim = ctx:limits()
	local iface = ctx:iface('administration-network-with-a-very-long-user-visible-name')
	local bridge = ctx:bridge('administration-network-with-a-very-long-user-visible-name')
	local vlan = ctx:vlan('administration-network-with-a-very-long-user-visible-name')
	local zone = ctx:zone('restricted-admin-firewall-zone')
	local mwan = ctx:mwan_iface('cellular-primary-uplink-with-long-name')
	local dns = ctx:dns_instance('ads-adult-host-policy-with-long-name')
	ok(#iface <= lim.logical_interface, 'logical interface length')
	ok(#bridge <= lim.bridge_device, 'bridge length')
	ok(#vlan <= lim.linux_device, 'vlan length')
	ok(#zone <= lim.firewall_zone, 'zone length')
	ok(#mwan <= lim.mwan_name, 'mwan length')
	ok(#dns <= lim.dnsmasq_instance, 'dnsmasq length')
	starts(iface, 'ad', 'semantic prefix retained')
	starts(bridge, 'brad', 'bridge semantic prefix retained')
	starts(zone, 're', 'zone semantic prefix retained')
	starts(ctx:iface('123-invalid-prefix-and-extremely-long'), 'x1', 'numeric leading prefix made safe')
end


function tests.test_modem_logical_interface_names_keep_readable_distinguishing_stems()
	local ctx = ok(names.allocate({
		segments = {}, interfaces = {
			modem_primary = {},
			modem_secondary = {},
			modem_primary_blue = {},
			modem_primary_green = {},
			modem_primary_bluey_green = {},
		}, firewall = { zones = {} }, wan = { members = {} },
	}))
	starts(ctx:iface('modem_primary'), 'mopri', 'modem primary stem')
	starts(ctx:iface('modem_secondary'), 'mosec', 'modem secondary stem')
	starts(ctx:iface('modem_primary_blue'), 'mprbl', 'modem primary blue stem')
	starts(ctx:iface('modem_primary_green'), 'mprgr', 'modem primary green stem')
	starts(ctx:iface('modem_primary_bluey_green'), 'mpbgr', 'modem primary bluey green stem')
	eq(#ctx:iface('modem_primary'), ctx:limits().logical_interface, 'stem plus hash length')
end

function tests.test_name_snapshot_is_stable()
	local intent = { segments = { adm = {}, jan = {} }, interfaces = {}, firewall = { zones = {} }, wan = { members = {} } }
	local a = ok(names.allocate(intent)):snapshot()
	local b = ok(names.allocate(intent)):snapshot()
	eq(a.names.logical_interface.adm, b.names.logical_interface.adm)
	eq(a.names.bridge_device.jan, b.names.bridge_device.jan)
end


function tests.test_mwan3_section_names_share_one_namespace()
	local ctx = ok(names.allocate({
		segments = {}, interfaces = {}, firewall = { zones = {} },
		wan = {
			members = {
				wan = { interface = 'wan' },
				balanced = { interface = 'balanced' },
			},
		},
	}))
	local lim = ctx:limits()
	local iface_wan = ctx:mwan_iface('wan')
	local member_wan = ctx:mwan_member('wan')
	local iface_balanced = ctx:mwan_iface('balanced')
	local member_balanced = ctx:mwan_member('balanced')
	local policy_balanced = ctx:mwan_policy('balanced')
	local rule_balanced = ctx:mwan_rule('balanced')
	local seen = {}
	for _, n in ipairs({ iface_wan, member_wan, iface_balanced, member_balanced, policy_balanced, rule_balanced }) do
		ok(#n <= lim.mwan_name, 'mwan3 name length')
		if seen[n] then fail('duplicate mwan3 UCI section name: ' .. tostring(n)) end
		seen[n] = true
	end
end

function tests.test_baseline_names_are_reserved()
	local ctx = ok(names.allocate({
		segments = {
			loopback = { kind = 'lan', firewall = { zone = 'defaults' } },
			globals = { kind = 'lan' },
		},
		interfaces = {}, firewall = { zones = { defaults = {} } }, wan = { members = {} },
	}))
	eq(ctx:iface('loopback') == 'loopback', false, 'segment id must not collide with network.loopback')
	eq(ctx:iface('globals') == 'globals', false, 'segment id must not collide with network.globals')
	eq(ctx:zone('defaults') == 'defaults', false, 'zone name must not collide with firewall defaults')
end

return tests
