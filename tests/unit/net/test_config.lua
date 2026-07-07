-- tests/unit/net/test_config.lua

local config = require 'services.net.config'

local tests = {}

local function ok(v, msg) if not v then error(msg or 'assertion failed', 2) end return v end
local function eq(a, b, msg) if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end end

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
	ok(err and err:find('net.segments.lan.shaping.egress', 1, true), 'segment shaping egress rejection error expected')
end

function tests.test_rejects_low_level_wan_shaping_fields()
	local cfg = sample_cfg()
	cfg.wan.members.gsm_a.shaping = { download_limit = '80mbit' }
	local intent, err = config.normalise(cfg, { rev = 1 })
	if intent ~= nil then error('expected wan member shaping download_limit to be rejected', 2) end
	ok(err and err:find('net.wan.members.gsm_a.shaping.download_limit', 1, true), 'wan shaping download_limit rejection error expected')
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
	eq(intent.segments.jan.shaping.host_default.download.sustained_rate, '2mbit')
	eq(intent.segments.jan.shaping.download.limit, '100mbit')
	eq(intent.dns.records['config.bigbox.home'].address, '172.28.8.1')
	eq(intent.routing.routes.starlink_admin.kind, 'host')
	eq(intent.routing.routes.starlink_admin.interface, 'wan')
	eq(intent.routing.routes.starlink_admin.target, '192.168.100.1')
	eq(intent.routing.routes.starlink_admin.netmask, '255.255.255.255')
	ok(intent.routing.routes.starlink_admin.description and intent.routing.routes.starlink_admin.description:find('Starlink', 1, true), 'Starlink route should carry context')
	eq(intent.firewall.rules.Allow_DNS_queries_RST.dest_port, '53')
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

return tests
