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

function tests.test_name_snapshot_is_stable()
	local intent = { segments = { adm = {}, jan = {} }, interfaces = {}, firewall = { zones = {} }, wan = { members = {} } }
	local a = ok(names.allocate(intent)):snapshot()
	local b = ok(names.allocate(intent)):snapshot()
	eq(a.names.logical_interface.adm, b.names.logical_interface.adm)
	eq(a.names.bridge_device.jan, b.names.bridge_device.jan)
end

return tests
