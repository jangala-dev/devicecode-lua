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
				dhcp = { enabled = true, pool = 'lan' },
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
			policy = 'weighted_failover',
			members = {
				gsm_a = { interface = 'wan_modem_a', weight = 70, priority = 1 },
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
		},
		dhcp = {
			pools = { lan = { segment = 'lan' } },
		},
		shaping = {
			enabled = true,
			profiles = { default = { fairness = 'per_client' } },
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
	eq(intent.stats.vpn_tunnels, 1)
end

function tests.test_accepts_config_service_record_shape_without_legacy_migration()
	local intent = ok(config.normalise({ rev = 12, data = sample_cfg() }, { generation = 4 }))
	eq(intent.rev, 12)
	eq(intent.generation, 4)
	eq(intent.wan.policy, 'weighted_failover')
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

return tests
