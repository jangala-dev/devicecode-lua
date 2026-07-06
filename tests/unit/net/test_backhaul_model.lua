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
    }, { now = 42 })

    local uplink = ok(model.uplinks.gsm_primary, 'gsm uplink expected')
    eq(uplink.state, 'sim_absent')
    eq(uplink.usable, false)
    eq(uplink.source.kind, 'gsm-uplink')
    eq(uplink.ifname, 'wwan0')
    eq(uplink.gsm, nil)
end

return tests
