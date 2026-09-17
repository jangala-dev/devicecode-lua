-- tests/unit/net/test_config.lua

local config = require 'services.net.config'

local tests = {}

local function ok(v, msg) if not v then error(msg or 'assertion failed', 2) end return v end
local function eq(a, b, msg)
	if a ~= b then
		error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2)
	end
end

local function sample_cfg()
	return {
		schema = config.SCHEMA,
		version = 1,
		product = 'bigbox',
		segments = {
			lan = {
				kind = 'lan',
				vlan = { id = 10 },
				addressing = { ipv4 = { mode = 'static', cidr = '172.28.10.1/24' } },
				dhcp = { enabled = true, start = 10, limit = 100, lease_time = '12h' },
				firewall = { zone = 'lan' },
			},
			guest = {
				kind = 'guest',
				vlan = 30,
				firewall = { zone = 'guest', isolation = 'internet_only' },
			},
		},
		interfaces = {
			lan_bridge = {
				kind = 'bridge',
				role = 'lan',
				segment = 'lan',
				members = { 'cm5_lan' },
			},
			wan_modem_a = {
				kind = 'cellular',
				role = 'wan',
				endpoint = { selector = 'modem.primary' },
			},
		},
		wan = {
			load_balancing = { policy = 'balanced' },
			rules = { https = { family = 'ipv4', proto = 'tcp', dest_port = '443', policy = 'balanced', sticky = true } },
			members = {
				gsm_a = { interface = 'wan_modem_a', weight = 70, mwan_metric = 1 },
			},
		},
		firewall = {
			zones = { lan = {}, guest = {}, wan = {} },
			policies = { guest_to_wan = { from = 'guest', to = 'wan', action = 'allow' } },
		},
		routing = {
			routes = {},
			rules = {},
		},
		dns = {
			upstreams = { '1.1.1.1', '8.8.8.8' },
			host_files = { base_dir = '/data/devicecode/dns/hosts', sources = { ads = { file = 'ads.hosts' } } },
		},
		dhcp = {
			defaults = { lease_time = '12h' },
			reservations = {},
		},
		vpn = {
			enabled = true,
			tunnels = { management = { kind = 'wireguard' } },
		},
		diagnostics = {
			reflectors = { cloud = { address = '1.1.1.1' } },
		},
		runtime = {
			apply = { debounce_s = 0.25 },
			observe = { interval_s = 5 },
		},
	}
end

function tests.test_accepts_only_current_cfg_net_schema()
	local intent = ok(config.normalise(sample_cfg(), { rev = 7, generation = 3 }))
	eq(intent.schema, config.INTENT_SCHEMA)
	eq(intent.config_schema, config.SCHEMA)
	eq(intent.rev, 7)
	eq(intent.generation, 3)
	eq(intent.version, 1)
	ok(intent.segments.lan, 'lan segment expected')
	ok(intent.interfaces.lan_bridge, 'lan interface expected')
	eq(intent.segments.guest.vlan.id, 30)
	eq(intent.stats.segments, 2)
	eq(intent.stats.interfaces, 2)
	eq(intent.stats.wan_members, 1)
	eq(intent.wan.members.gsm_a.metric, 1)
	eq(intent.wan.members.gsm_a.mwan_metric, nil)
	eq(intent.wan.rules.https.proto, 'tcp')
	eq(intent.wan.rules.https.dest_port, '443')
	eq(intent.wan.rules.https.policy, 'balanced')
	eq(intent.wan.rules.https.sticky, true)
	eq(intent.stats.vpn_tunnels, 1)
end

function tests.test_accepts_config_service_record_shape_without_legacy_migration()
	local intent = ok(config.normalise({ rev = 12, data = sample_cfg() }, { generation = 4 }))
	eq(intent.rev, 12)
	eq(intent.generation, 4)
	eq(intent.wan.policy, nil)
end





function tests.test_rejects_top_level_shaping()
	local cfg = sample_cfg()
	cfg.shaping = { enabled = true }
	local intent, err = config.normalise(cfg, { rev = 1 })
	if intent ~= nil then error('expected top-level shaping to be rejected', 2) end
	ok(err and err:find('cfg.net.shaping', 1, true), 'top-level shaping rejection error expected')
end

function tests.test_rejects_low_level_segment_shaping_fields()
	local cfg = sample_cfg()
	cfg.segments.lan.shaping = { egress = { enabled = true } }
	local intent, err = config.normalise(cfg, { rev = 1 })
	if intent ~= nil then error('expected segment shaping egress to be rejected', 2) end
	ok(err and err:find('net.segments.lan.shaping.egress', 1, true),
		'segment shaping egress rejection error expected')
end

function tests.test_rejects_low_level_wan_shaping_fields()
	local cfg = sample_cfg()
	cfg.wan.members.gsm_a.shaping = { download_limit = '80mbit' }
	local intent, err = config.normalise(cfg, { rev = 1 })
	if intent ~= nil then error('expected wan member shaping download_limit to be rejected', 2) end
	ok(err and err:find('net.wan.members.gsm_a.shaping.download_limit', 1, true),
		'wan shaping download_limit rejection error expected')
end

function tests.test_rejects_implicit_static_route_without_kind()
	local cfg = sample_cfg()
	cfg.routing.routes.legacy = { target = '192.168.100.1', interface = 'wan_modem_a' }
	local intent, err = config.normalise(cfg, { rev = 1 })
	if intent ~= nil then error('expected route without kind to be rejected', 2) end
	ok(err and err:find('net.routing.routes.legacy.kind', 1, true), 'route kind error expected')
end

function tests.test_rejects_subnet_route_without_netmask()
	local cfg = sample_cfg()
	cfg.routing.routes.bad_subnet = { kind = 'subnet', target = '192.168.100.0', interface = 'wan_modem_a' }
	local intent, err = config.normalise(cfg, { rev = 1 })
	if intent ~= nil then error('expected subnet route without netmask to be rejected', 2) end
	ok(err and err:find('net.routing.routes.bad_subnet.netmask', 1, true), 'route netmask error expected')
end

function tests.test_rejects_unknown_route_interface()
	local cfg = sample_cfg()
	cfg.routing.routes.starlink_admin = { kind = 'host', target = '192.168.100.1', interface = 'missing' }
	local intent, err = config.normalise(cfg, { rev = 1 })
	if intent ~= nil then error('expected unknown route interface to be rejected', 2) end
	ok(err and err:find('net.routing.routes.starlink_admin.interface', 1, true), 'route interface error expected')
end

function tests.test_rejects_mwan_rule_for_unknown_policy()
	local cfg = sample_cfg()
	cfg.wan.rules.https.policy = 'not_declared'
	local intent, err = config.normalise(cfg, { rev = 1 })
	eq(intent, nil)
	ok(err and err:find('wan%.rules%.https%.policy', 1, false), 'policy error expected')
end

function tests.test_rejects_missing_or_wrong_schema()
	local intent, err = config.normalise({ segments = {} }, { rev = 1 })
	if intent ~= nil then error('expected config without schema to be rejected', 2) end
	ok(err and err:find('devicecode.config/net/1', 1, true), 'schema error expected')

	intent, err = config.normalise({ schema = 'legacy', network = {} }, { rev = 1 })
	if intent ~= nil then error('expected legacy network shape to be rejected', 2) end
	ok(err and err:find('devicecode.config/net/1', 1, true), 'legacy shape must be rejected')
end

function tests.test_rejects_arrays_for_core_maps()
	local cfg = sample_cfg()
	cfg.segments = { { id = 'lan', kind = 'lan' } }
	local intent, err = config.normalise(cfg, { rev = 1 })
	if intent ~= nil then error('expected array segments to be rejected', 2) end
	ok(err and err:find('map keyed by id', 1, true), 'map keyed by id error expected')
end


local function read_project_file(rel)
	local candidates = { rel, '../' .. rel }
	for i = 1, #candidates do
		local f = io.open(candidates[i], 'rb')
		if f then local data = f:read('*a'); f:close(); return data end
	end
	return nil, 'unable to read ' .. rel
end

function tests.test_bigbox_config_uses_clean_segment_authority_shape()
	local cjson = require 'cjson.safe'
	local text = ok(read_project_file('src/configs/bigbox-v1-cm-2.json'))
	local doc = ok(cjson.decode(text), 'bigbox config must decode')
	local intent = ok(config.normalise(doc.net, { generation = 1 }))
	eq(intent.dhcp.pools, nil, 'top-level dhcp pools must not be authoritative')
	eq(intent.segments.jan.dhcp.enabled, true)
	eq(intent.segments.jan.dns.host_files[1], 'ads')
	eq(intent.segments.jan.dns.host_files[2], 'adult')
	eq(intent.segments.jan.shaping.host_default.download.sustained_rate, '500kbit')
	eq(intent.segments.jan.shaping.host_default.download.peak_rate, '2mbit')
	eq(intent.segments.jan.shaping.host_default.upload.sustained_rate, '250kbit')
	eq(intent.segments.jan.shaping.host_default.upload.peak_rate, '1mbit')
	eq(intent.segments.jan.shaping.download, nil)
	eq(intent.segments.jan.shaping.upload, nil)
	eq(intent.dns.records['config.bigbox.home'].address, '172.28.8.1')
	eq(intent.routing.routes.starlink_admin.kind, 'host')
	eq(intent.routing.routes.starlink_admin.interface, 'wan')
	eq(intent.routing.routes.starlink_admin.target, '192.168.100.1')
	eq(intent.routing.routes.starlink_admin.netmask, '255.255.255.255')
	ok(intent.routing.routes.starlink_admin.description
		and intent.routing.routes.starlink_admin.description:find('Starlink', 1, true),
		'Starlink route should carry context')
	eq(intent.firewall.rules.Allow_DNS_queries_RST.dest_port, '53')
end



function tests.test_bigbox_v1_cm_preserves_original_symmetric_host_shaping()
	local cjson = require 'cjson.safe'
	local text = ok(read_project_file('src/configs/bigbox-v1-cm.json'))
	local doc = ok(cjson.decode(text), 'bigbox-v1-cm config must decode')
	local intent = ok(config.normalise(doc.net, { generation = 1 }))
	local shaping = intent.segments.jan.shaping.host_default
	for _, direction in ipairs({ 'download', 'upload' }) do
		eq(shaping[direction].sustained_rate, '400kbit')
		eq(shaping[direction].peak_rate, '2mbit')
		eq(shaping[direction].burst_budget, '200k')
	end
end

function tests.test_rejects_cross_domain_unknown_segment_reference()
	local cfg = sample_cfg()
	cfg.interfaces.bad = { kind = 'bridge', segment = 'missing' }
	local intent, err = config.normalise(cfg, { rev = 1 })
	if intent ~= nil then error('expected unknown segment reference to be rejected', 2) end
	ok(err and err:find('unknown segment', 1, true), 'unknown segment error expected')
end

function tests.test_rejects_unknown_wan_interface_when_interface_catalogue_present()
	local cfg = sample_cfg()
	cfg.wan.members.bad = { interface = 'missing' }
	local intent, err = config.normalise(cfg, { rev = 1 })
	if intent ~= nil then error('expected unknown WAN interface to be rejected', 2) end
	ok(err and err:find('unknown interface', 1, true), 'unknown interface error expected')
end

local function shared_cfg()
	local cfg = sample_cfg()
	cfg.segments = {
		adm = { addressing = { ipv4 = { mode = 'static', cidr = '172.28.8.1/24',
			reserved_ranges = { shared_devices = { from = '172.28.8.250', to = '172.28.8.254' } } } },
			dhcp = { enabled = true, start = 10, limit = 240 }, firewall = { zone = 'lan' } },
		jan = { addressing = { ipv4 = { mode = 'static', cidr = '172.28.32.1/24' } }, firewall = { zone = 'guest' } },
	}
	cfg.interfaces.lan_bridge.segment = 'adm'
	cfg.dns.service_discovery = { shared_devices = {
		enabled = true, source_segment = 'adm', advertise_to = { 'jan' }, address_range = 'shared_devices', family = 'ipv4',
		services = { ipp = { type = '_ipp._tcp', protocol = 'tcp', ports = { 631 } } },
	} }
	cfg.firewall.rules = {
		shared = { family = 'ipv4', src = 'guest', dest = 'lan', proto = 'tcp', dest_port = '631', target = 'ACCEPT',
			dest_ip = { '172.28.8.250/32', '172.28.8.251/32', '172.28.8.252/32', '172.28.8.253/32', '172.28.8.254/32' } },
		mdns = { family = 'ipv4', src = 'guest', dest_ip = '224.0.0.251',
			proto = 'udp', dest_port = '5353', target = 'ACCEPT' },
	}
	return cfg
end

local function rejects(cfg, text)
	local intent, err = config.normalise(cfg)
	eq(intent, nil, 'invalid config unexpectedly accepted')
	ok(type(err) == 'string' and err:find(text, 1, true), 'expected ' .. text .. ', got ' .. tostring(err))
end

function tests.test_shared_device_intent_is_explicit_and_does_not_mutate_input()
	local cfg = shared_cfg()
	local intent = ok(config.normalise(cfg))
	local policy = intent.dns.service_discovery.shared_devices
	eq(policy.source_segment, 'adm'); eq(policy.advertise_to[1], 'jan'); eq(policy.address_range, 'shared_devices')
	eq(policy.family, 'ipv4'); eq(policy.services.ipp.type, '_ipp._tcp'); eq(policy.services.ipp.ports[1], 631)
	eq(intent.segments.adm.dhcp.start, 10); eq(intent.segments.adm.dhcp.limit, 240)
	policy.services.ipp.ports[1] = 9999
	intent.segments.adm.addressing.ipv4.reserved_ranges.shared_devices.from = '172.28.8.249'
	eq(cfg.dns.service_discovery.shared_devices.services.ipp.ports[1], 631)
	eq(cfg.segments.adm.addressing.ipv4.reserved_ranges.shared_devices.from, '172.28.8.250')
end

function tests.test_reserved_range_rejects_invalid_boundaries()
	local cases = {
		{ 'bad', '172.28.8.254', 'IPv4' },
		{ '172.28.8.254', '172.28.8.250', 'start must not exceed' },
		{ '172.28.8.250', '172.28.9.1', 'outside subnet' },
		{ '172.28.8.1', '172.28.8.1', 'network, router and broadcast' },
		{ '172.28.8.0', '172.28.8.0', 'network, router and broadcast' },
		{ '172.28.8.250', '172.28.8.255', 'network, router and broadcast' },
		{ '172.28.8.249', '172.28.8.254', 'overlaps dynamic DHCP' },
	}
	for _, case in ipairs(cases) do
		local cfg = shared_cfg()
		cfg.segments.adm.addressing.ipv4.reserved_ranges.shared_devices = { from = case[1], to = case[2] }
		rejects(cfg, case[3])
	end
	local cfg = shared_cfg()
	cfg.segments.adm.addressing.ipv4.cidr = '172.28.8.252/24'
	rejects(cfg, 'network, router and broadcast')
end

function tests.test_reserved_range_is_typed_and_requires_static_subnet()
	for _, value in ipairs({ 'bad', { 'bad' }, { shared_devices = false },
		{ shared_devices = { from = '172.28.8.250', to = '172.28.8.254', typo = true } } }) do
		local cfg = shared_cfg()
		cfg.segments.adm.addressing.ipv4.reserved_ranges = value
		rejects(cfg, 'reserved_ranges')
	end
	for _, change in ipairs({ { 'mode', 'dhcp' }, { 'cidr', 'bad' } }) do
		local cfg = shared_cfg(); cfg.segments.adm.addressing.ipv4[change[1]] = change[2]
		rejects(cfg, 'static IPv4 CIDR')
	end
	local cfg = shared_cfg()
	cfg.segments.adm.addressing.ipv4.reserved_ranges.other = { from = '172.28.8.251', to = '172.28.8.253' }
	rejects(cfg, 'reserved ranges overlap')
end

function tests.test_dhcp_effective_pool_uses_start_limit_aliases_and_defaults()
	local cfg = shared_cfg()
	cfg.segments.adm.dhcp.limit = 241
	rejects(cfg, 'overlaps dynamic DHCP')
	cfg = shared_cfg(); cfg.segments.adm.dhcp = { enabled = true, range_start = 10, range_limit = 241 }
	rejects(cfg, 'overlaps dynamic DHCP')
	cfg = shared_cfg(); cfg.segments.adm.dhcp = { enabled = true }
	cfg.dhcp.defaults.start = 10; cfg.dhcp.defaults.limit = 241
	rejects(cfg, 'overlaps dynamic DHCP')
	cfg.segments.adm.dhcp.start = 10; cfg.segments.adm.dhcp.limit = 240
	ok(config.normalise(cfg), 'segment settings override defaults')
	cfg = shared_cfg(); cfg.segments.adm.dhcp = { enabled = true }
	ok(config.normalise(cfg), 'fallback pool 100..249 is disjoint')
	cfg.segments.adm.dhcp.enabled = false; cfg.dhcp.defaults.start = 250
	ok(config.normalise(cfg), 'disabled DHCP has no dynamic pool')
end

function tests.test_dhcp_boundaries_are_computed_from_network_not_router()
	local cfg = shared_cfg()
	cfg.segments.adm.addressing.ipv4.cidr = '172.28.8.5/23'
	cfg.segments.adm.dhcp.start = 256; cfg.segments.adm.dhcp.limit = 100
	ok(config.normalise(cfg))
	cfg.segments.adm.dhcp.start = 249; cfg.segments.adm.dhcp.limit = 2
	rejects(cfg, 'overlaps dynamic DHCP')
	cfg = shared_cfg(); cfg.segments.adm.dhcp.limit = 500
	rejects(cfg, 'usable subnet addresses')
end

function tests.test_manual_only_range_rejects_all_reservation_aliases_and_hints()
	for _, key in ipairs({ 'ip', 'address' }) do
		local cfg = shared_cfg()
		cfg.dhcp.reservations.printer = { [key] = '172.28.8.250', segment = 'jan', mac = '02:00:00:00:00:01' }
		rejects(cfg, 'manual-only reserved range')
		cfg.dhcp.reservations.printer[key] = '172.28.8.249'
		ok(config.normalise(cfg))
	end
end

function tests.test_reserved_ranges_reject_ambiguous_interface_addressing()
	local cfg = shared_cfg()
	cfg.interfaces.lan_bridge.addressing = { ipv4 = { cidr = '172.28.9.1/24' } }
	rejects(cfg, 'interface addressing overrides')
end

function tests.test_discovery_references_and_destinations()
	local cases = {
		{ 'source_segment', 'missing', 'unknown segment' },
		{ 'advertise_to', { 'missing' }, 'unknown segment' },
		{ 'advertise_to', { 'adm' }, 'source segment cannot' },
		{ 'advertise_to', { 'jan', 'jan' }, 'duplicate destination' },
		{ 'advertise_to', {}, 'must not be empty' },
		{ 'address_range', 'missing', 'unknown reserved range' },
		{ 'family', 'ipv6', 'only ipv4' },
		{ 'enabled', 'yes', 'boolean' },
		{ 'backend', 'anything', 'field is not part' },
	}
	for _, case in ipairs(cases) do
		local cfg = shared_cfg(); cfg.dns.service_discovery.shared_devices[case[1]] = case[2]
		rejects(cfg, case[3])
	end
end

function tests.test_discovery_service_validation()
	for _, service in ipairs({
		{}, { type = '', protocol = 'tcp', ports = { 631 } },
		{ type = '_ipp._tcp', protocol = 'bad', ports = { 631 } },
		{ type = '_ipp._tcp', protocol = 'udp', ports = { 631 } },
		{ type = '_ipp._tcp', protocol = 'tcp', ports = { 0 } },
		{ type = '_ipp._tcp', protocol = 'tcp', ports = { 65536 } },
		{ type = '_ipp._tcp', protocol = 'tcp', ports = { 631.5 } },
		{ type = '_ipp._tcp', protocol = 'tcp', ports = { '631' } },
		{ type = '_ipp._tcp', protocol = 'tcp', ports = {} },
		{ type = '_ipp._tcp', protocol = 'tcp', ports = { 631, 631 } },
		{ type = '_ipp._tcp', protocol = 'tcp', ports = { [1] = 631, [3] = 632 } },
	}) do
		local cfg = shared_cfg(); cfg.dns.service_discovery.shared_devices.services.ipp = service
		rejects(cfg, 'services.ipp')
	end
	local cfg = shared_cfg(); cfg.dns.service_discovery.shared_devices.services = {}
	rejects(cfg, 'at least one service')
	cfg = shared_cfg(); local services = cfg.dns.service_discovery.shared_devices.services
	services.duplicate = services.ipp; rejects(cfg, 'duplicate service type')
end

function tests.test_discovery_disabled_preserves_semantics_without_removing_access()
	local cfg = shared_cfg(); cfg.dns.service_discovery.shared_devices.enabled = false
	local intent = ok(config.normalise(cfg))
	eq(intent.dns.service_discovery.shared_devices.enabled, false)
	eq(intent.firewall.rules.shared.dest_port, '631')
	cfg.dns.service_discovery = nil
	intent = ok(config.normalise(cfg))
	eq(next(intent.dns.service_discovery), nil)
	eq(intent.firewall.rules.shared.dest_port, '631')
end

function tests.test_firewall_rejects_invalid_zones_addresses_and_ports()
	local cases = {
		{ 'src', 'missing' }, { 'dest', 'missing' }, { 'family', 'ipvx' }, { 'proto', 'typo' }, { 'target', 'typo' },
		{ 'src_ip', '999.1.1.1' }, { 'dest_ip', { '172.28.8.250/33' } }, { 'dest_ip', '172.28.8.250/' },
		{ 'src_port', '0' }, { 'dest_port', '65536' }, { 'dest_port', '632-631' }, { 'dest_port', 1.5 },
		{ 'src_ip', '2001:::1' }, { 'src_ip', '2001:db8::/129' },
	}
	for _, case in ipairs(cases) do
		local cfg = shared_cfg(); cfg.firewall.rules.shared[case[1]] = case[2]
		rejects(cfg, 'firewall.rules.shared.' .. case[1])
	end
end

function tests.test_firewall_preserves_existing_list_range_and_ipv6_syntax()
	local cfg = sample_cfg()
	cfg.firewall.rules = {
		dns = { src = 'guest', proto = 'tcp udp', dest_port = '53', target = 'ACCEPT' },
		dhcp = { src = 'guest', proto = { 'udp' }, src_port = '67-68', dest_port = '67:68' },
		other = { src = '*', dest = 'wan', proto = 'esp', src_ip = '!172.28.10.1/32', target = 'ACCEPT' },
		ipv6 = { family = 'ipv6', src = 'guest', proto = 'icmpv6', src_ip = { '::1', '2001:db8::/64', '::ffff:192.0.2.1' } },
	}
	local intent = ok(config.normalise(cfg))
	eq(intent.firewall.rules.dns.proto, 'tcp udp')
	eq(intent.firewall.rules.dhcp.src_port, '67-68')
	eq(intent.firewall.rules.ipv6.src_ip[3], '::ffff:192.0.2.1')
end

function tests.test_shared_firewall_cannot_widen_reserved_destinations()
	for _, addresses in ipairs({ { '172.28.8.248/29' }, { '172.28.8.73/32' },
		{ '172.28.8.250/32', '172.28.8.249/32' }, { '!172.28.8.250/32' } }) do
		local cfg = shared_cfg(); cfg.firewall.rules.shared.dest_ip = addresses
		rejects(cfg, 'declared reserved range')
	end
	local cfg = shared_cfg(); cfg.firewall.rules.shared.dest_ip = nil
	rejects(cfg, 'explicit destinations')
	cfg = shared_cfg(); cfg.segments.adm.addressing.ipv4.reserved_ranges.shared_devices.to = '172.28.8.253'
	rejects(cfg, 'declared reserved range')
	cfg = shared_cfg(); cfg.firewall.rules.shared.proto = 'tcp udp'; cfg.firewall.rules.shared.dest_port = '630-632'
	cfg.firewall.rules.shared.dest_ip = '172.28.8.73'
	rejects(cfg, 'declared reserved range')
end

function tests.test_section_one_product_config_and_legacy_products()
	local json = require 'cjson.safe'
	for _, filename in ipairs({ 'bigbox-ss.json', 'bigbox-v1-cm.json', 'bigbox-v1-cm-2.json' }) do
		local doc = ok(json.decode(ok(read_project_file('src/configs/' .. filename))))
		local intent = ok(config.normalise(doc.net))
		eq(intent.segments.adm.dhcp.start, 10); eq(intent.segments.adm.dhcp.limit, 240)
		if filename == 'bigbox-v1-cm-2.json' then
			local range = intent.segments.adm.addressing.ipv4.reserved_ranges.shared_devices
			eq(range.from, '172.28.8.250'); eq(range.to, '172.28.8.254')
			eq(intent.dns.service_discovery.shared_devices.services.ipp.ports[1], 631)
			local rule = intent.firewall.rules.Allow_Guest_Shared_Devices_IPP
			eq(#rule.dest_ip, 5); eq(rule.dest_ip[5], '172.28.8.254/32'); eq(rule.dest_port, '631')
			eq(intent.firewall.rules.Allow_Guest_mDNS.dest, nil)
			eq(intent.firewall.rules.Allow_Guest_mDNS.dest_ip, '224.0.0.251')
		else
			eq(next(intent.dns.service_discovery), nil)
		end
	end
end

function tests.test_section_one_semantics_reach_hal_unchanged()
	local fibers = require 'fibers'
	local op = require 'fibers.op'
	local realiser = require 'services.net.intent_realiser'
	local client = require 'services.net.hal_client'
	local intent = ok(config.normalise(shared_cfg()))
	local realised = realiser.realise(intent, {})
	local captured
	local cap = { call_control_op = function(_, operation, args)
		eq(operation, 'apply'); captured = args.intent
		return op.always({ ok = true, reason = { ok = true } })
	end }
	fibers.run(function()
		local hal = client.new(nil, { resolve_defaults = false, network_config_cap = cap })
		ok(fibers.perform(hal:apply_intent_op(realised)).ok)
	end)
	eq(captured.dns.service_discovery.shared_devices.source_segment, 'adm')
	eq(captured.dns.service_discovery.shared_devices.services.ipp.ports[1], 631)
	eq(captured.segments.adm.addressing.ipv4.reserved_ranges.shared_devices.to, '172.28.8.254')
	eq(captured.dns.service_discovery.shared_devices.backend, nil)
end

return tests
