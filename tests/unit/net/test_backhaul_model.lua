-- tests/unit/net/test_backhaul_model.lua

local backhaul = require 'services.net.backhaul_model'

local tests = {}
local function fail(msg) error(msg or 'assertion failed', 2) end
local function eq(a, b, msg) if a ~= b then fail((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function ok(v, msg) if not v then fail(msg or 'expected truthy') end return v end

function tests.test_reduces_hal_multiwan_facts_to_semantic_backhaul()
    local model = backhaul.reduce({
        wan = { members = { wan = { interface = 'wan', metric = 10 } } },
        observed = {
            snapshot = {
                multiwan = {
                    backend = 'openwrt',
                    source = 'mwan3',
                    interfaces_by_semantic = {
                        wan = {
                            interface = 'wan',
                            ifname = 'eth0.2',
                            state = 'online',
                            usable = true,
                            uptime_s = 123,
                            age_s = 4,
                            metric = 10,
                        },
                    },
                },
                live = {
                    interfaces = {
                        wan = { ipv4 = { { address = '203.0.113.10', mask = 24 } } },
                    },
                },
            },
        },
    }, { now = 42 })

    eq(model.state, 'ok')
    local wan = ok(model.uplinks.wan, 'wan uplink expected')
    eq(wan.state, 'online')
    eq(wan.usable, true)
    eq(wan.uptime_s, 123)
    eq(wan.source.kind, 'host-multiwan')
    eq(wan.source.tool, 'mwan3')
    eq(wan.path_address.address, '203.0.113.10')
end


function tests.test_backhaul_uses_mwan3_for_status_and_endpoint_for_device_name()
    local model = backhaul.reduce({
        interfaces = {
            wan = { endpoint = { ifname = 'vl-wan' } },
        },
        wan = { members = { wan = { interface = 'wan', metric = 10 } } },
        observed = {
            snapshot = {
                multiwan = {
                    backend = 'openwrt',
                    source = 'mwan3',
                    interfaces_by_semantic = {
                        wan = { interface = 'wan', state = 'online', usable = true },
                    },
                },
            },
        },
    }, { now = 42 })

    local wan = ok(model.uplinks.wan, 'wan uplink expected')
    eq(wan.state, 'online')
    eq(wan.usable, true)
    eq(wan.ifname, 'vl-wan')
    eq(wan.source.tool, 'mwan3')
end

function tests.test_gsm_uplink_is_mapped_without_hal_backend_terms()
    local model = backhaul.reduce({
        wan = {
            members = {
                gsm_primary = { interface = 'modem_primary', source = { kind = 'gsm-uplink', id = 'primary' } },
            },
        },
        sources = {
            gsm_uplinks = {
                primary = {
                    state = 'sim_absent',
                    connected = false,
                    linux = { ifname = 'wwan0' },
                },
            },
        },
        observed = {
            snapshot = {
                live = { interfaces = { wwan0 = { ipv4 = { { address = '10.1.2.3' } } } } },
            },
        },
    }, { now = 42 })

    local uplink = ok(model.uplinks.gsm_primary, 'gsm uplink expected')
    eq(uplink.state, 'sim_absent')
    eq(uplink.usable, false)
    eq(uplink.source.kind, 'gsm-uplink')
    eq(uplink.ifname, 'wwan0')
    eq(uplink.path_address.address, '10.1.2.3')
    eq(uplink.gsm, nil)
end

return tests
