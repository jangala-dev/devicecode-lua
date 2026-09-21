package.path = './src/?.lua;./src/?/init.lua;./vendor/lua-fibers/src/?.lua;./vendor/lua-fibers/src/?/init.lua;'
    .. './vendor/lua-bus/src/?.lua;./vendor/lua-bus/src/?/init.lua;./vendor/lua-trie/src/?.lua;' .. package.path
local fibers = require 'fibers'
local json = require 'cjson.safe'
local net = require 'services.net.config'
local provider_mod = require 'services.hal.backends.network.providers.openwrt.init'
local names = require 'services.hal.backends.network.providers.openwrt.names'
local f = assert(io.open('src/configs/bigbox-v1-cm-2.json'))
local product = assert(json.decode(f:read('*a'))); f:close()
local intent = assert(net.normalise((net.extract_payload(product.net))))
local adm, jan = intent.segments.adm, intent.segments.jan
adm.shaping, jan.shaping = nil, nil
intent.segments = {
    adm = adm, jan = jan,
    isolated = { addressing = { ipv4 = { mode = 'static', cidr = '172.28.100.1/24' } }, firewall = { zone = 'isolated' } },
    management = { addressing = { ipv4 = { mode = 'static', cidr = '192.168.1.1/24' } }, firewall = { zone = 'management' } },
    wan = { kind = 'wan', firewall = { zone = 'wan' } },
}
intent.interfaces = {
    source_bridge = { kind = 'bridge', segment = 'adm', members = { 'dcm-adm' } },
    client_bridge = { kind = 'bridge', segment = 'jan', members = { 'dcm-jan' } },
    isolated_bridge = { kind = 'bridge', segment = 'isolated', members = { 'dcm-isolated' } },
    lan = { kind = 'bridge', segment = 'management', members = { 'eth0' } },
    wan = { kind = 'ethernet', role = 'wan', segment = 'wan', endpoint = { ifname = 'eth1' },
        addressing = { ipv4 = { mode = 'dhcp' } } },
}
intent.firewall = {
    defaults = { input = 'REJECT', output = 'ACCEPT', forward = 'REJECT' },
    zones = {
        lan = { input = 'ACCEPT', output = 'ACCEPT', forward = 'REJECT' },
        lan_rst = { input = 'REJECT', output = 'ACCEPT', forward = 'REJECT' },
        isolated = { input = 'ACCEPT', output = 'ACCEPT', forward = 'REJECT' },
        management = { input = 'ACCEPT', output = 'ACCEPT', forward = 'REJECT' },
        wan = { input = 'REJECT', output = 'ACCEPT', forward = 'REJECT', masq = true },
    },
    policies = { management_wan = { from = 'management', to = 'wan' } },
    rules = {
        ipp = intent.firewall.rules.Allow_Guest_Shared_Devices_IPP,
        mdns = intent.firewall.rules.Allow_Guest_mDNS,
    },
}
intent.wan, intent.shaping, intent.dhcp = {}, {}, {}
intent.routing = { routes = {} }
local allocated = names.allocate(intent, {})
fibers.run(function()
    local provider = assert(provider_mod.new({
        confdir = '/tmp/devicecode-mdns-test/conf', savedir = '/tmp/devicecode-mdns-test/save',
        run_cmd = function() return true end,
    }))
    local plan = fibers.perform(provider:plan_op({ intent = intent }))
    assert(plan.ok, plan.err)
    local result = fibers.perform(provider:apply_op({ intent = intent }))
    assert(result.ok, result.err)
    local out = assert(io.open('/tmp/devicecode-mdns-test/devices.json', 'w'))
    out:write(assert(json.encode({
        adm = allocated:bridge('source_bridge'), jan = allocated:bridge('client_bridge'),
        isolated = allocated:bridge('isolated_bridge'),
    })))
    out:close()
    local activation = assert(io.open('/tmp/devicecode-mdns-test/activate.sh', 'w'))
    activation:write(require('services.hal.backends.network.providers.openwrt.mdns_repeater').activation_command()[3])
    activation:close()
    provider:terminate('rendered')
end)
