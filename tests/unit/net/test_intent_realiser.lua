-- tests/unit/net/test_intent_realiser.lua

local config = require 'services.net.config'
local realiser = require 'services.net.intent_realiser'

local tests = {}
local function ok(v, msg) if not v then error(msg or 'assertion failed', 2) end return v end
local function eq(a, b, msg) if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end end

local function base_cfg()
	return {
		schema = config.SCHEMA,
		version = 1,
		segments = {
			wan = { kind = 'wan', vlan = { id = 4 }, firewall = { zone = 'wan' }, addressing = { ipv4 = { mode = 'dhcp', peerdns = false } } },
		},
		interfaces = {},
		firewall = { zones = { wan = { masq = true } }, policies = {} },
		routing = {}, dns = {}, dhcp = {}, vpn = {}, diagnostics = {},
		wan = {
			enabled = true,
			members = {
				wan = { interface = 'wan', mwan_metric = 1, weight = 1 },
				modem_primary = { interface = 'modem_primary', mwan_metric = 1, weight = 1, source = { kind = 'gsm-uplink', id = 'primary' } },
				modem_secondary = { interface = 'modem_secondary', mwan_metric = 1, weight = 1, source = { kind = 'gsm-uplink', id = 'secondary' } },
			},
		},
	}
end

function tests.test_unavailable_gsm_uplinks_are_not_realised()
	local intent = ok(config.normalise(base_cfg(), { rev = 1, generation = 1 }))
	local realised = realiser.realise(intent, { gsm_uplinks = {} })
	eq(realised.wan.members.wan.interface, 'wan')
	eq(realised.wan.members.modem_primary, nil)
	eq(realised.wan.members.modem_secondary, nil)
	eq(realised.interfaces.modem_primary, nil)
	eq(realised.segments.wan.addressing.ipv4.metric, 11)
end

function tests.test_gsm_uplink_ifname_realises_modem_interface()
	local intent = ok(config.normalise(base_cfg(), { rev = 1, generation = 1 }))
	local realised = realiser.realise(intent, { gsm_uplinks = { primary = { linux = { ifname = 'wwan1' } } } })
	local iface = ok(realised.interfaces.modem_primary)
	eq(iface.role, 'wan')
	eq(iface.endpoint.ifname, 'wwan1')
	eq(iface.addressing.ipv4.metric, 12)
	eq(realised.wan.members.modem_primary.interface, 'modem_primary')
	eq(realised.wan.members.modem_secondary, nil)
end

function tests.test_rejects_non_gsm_uplink_source()
	local cfg = base_cfg()
	cfg.wan.members.modem_primary.source = { kind = 'unsupported-source', id = 'primary' }
	local intent, err = config.normalise(cfg, { rev = 1, generation = 1 })
	eq(intent, nil)
	ok(err and err:find('gsm%-uplink'), 'gsm-uplink error expected')
end

return tests
