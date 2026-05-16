#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(CDPATH= cd -- "$VM_DIR/../../.." && pwd)"
SSH="$VM_DIR/scripts/ssh"
SCP_TO="$VM_DIR/scripts/scp-to"
REMOTE="/tmp/devicecode-network-provider-test"
WORK="$VM_DIR/work/network-provider-test"

mkdir -p "$WORK"

cat > "$WORK/run_openwrt_network_provider_apply.lua" <<'LUA'
package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './vendor/lua-fibers/src/?.lua',
  './vendor/lua-fibers/src/?/init.lua',
  './vendor/lua-bus/src/?.lua',
  './vendor/lua-bus/src/?/init.lua',
  './vendor/lua-trie/src/?.lua',
  './vendor/lua-trie/src/?/init.lua',
  package.path,
}, ';')

local fibers = require 'fibers'
local bus = require 'bus'
local trie = require 'trie'
local uci = require 'uci'
local provider_loader = require 'services.hal.backends.network.provider'

assert(type(bus.new) == 'function', 'vendored bus did not load')
assert(type(trie.new_pubsub) == 'function', 'vendored trie did not load')

local perform = fibers.perform

local function fail(msg) error(msg, 2) end
local function eq(a, b, msg)
  if a ~= b then
    fail((msg or 'values differ') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a))
  end
end

local function assert_list(v, expected, label)
  if type(v) ~= 'table' then fail((label or 'list') .. ' should be a table, got ' .. type(v)) end
  eq(#v, #expected, (label or 'list') .. ' length')
  for i = 1, #expected do eq(v[i], expected[i], (label or 'list') .. '[' .. i .. ']') end
end

local function mkdir_p(path)
  local ok = os.execute("mkdir -p '" .. path .. "'")
  if ok ~= true and ok ~= 0 then fail('mkdir failed for ' .. path) end
end

local tmp = '/tmp/dc-network-provider-apply'
os.execute("rm -rf '" .. tmp .. "'")
local conf = tmp .. '/conf'
local save = tmp .. '/save'
mkdir_p(conf)
mkdir_p(save)
for _, pkg in ipairs({ 'network', 'dhcp', 'firewall', 'mwan3' }) do
  local f = assert(io.open(conf .. '/' .. pkg, 'w'))
  f:write('# devicecode OpenWrt network provider test\n')
  f:close()
end

local restarts = {}

local intent = {
  schema = 'devicecode.net.intent/1',
  rev = 101,
  generation = 3,
  segments = {
    lan = {
      kind = 'lan',
      vlan = { id = 10 },
      addressing = { ipv4 = { mode = 'static', cidr = '192.168.10.1/24' } },
      dhcp = { enabled = true, start = 20, limit = 50, leasetime = '6h' },
      firewall = { zone = 'lan' },
    },
    wan = {
      kind = 'wan',
      firewall = { zone = 'wan' },
    },
  },
  interfaces = {
    lan = {
      kind = 'bridge',
      role = 'lan',
      segment = 'lan',
      members = { 'eth0', 'eth1' },
      addressing = { ipv4 = { mode = 'static', cidr = '192.168.10.1/24' } },
    },
    wan = {
      kind = 'ethernet',
      role = 'wan',
      segment = 'wan',
      endpoint = { ifname = 'eth2' },
      addressing = { ipv4 = { mode = 'dhcp', peerdns = false, metric = 10 } },
    },
  },
  dns = {
    enabled = true,
    upstreams = { '1.1.1.1', '8.8.8.8' },
  },
  dhcp = {},
  firewall = {
    defaults = { input = 'REJECT', output = 'ACCEPT', forward = 'REJECT' },
    zones = {
      lan = { input = 'ACCEPT', output = 'ACCEPT', forward = 'REJECT' },
      wan = { input = 'REJECT', output = 'ACCEPT', forward = 'REJECT', masq = true, mtu_fix = true },
    },
    policies = {
      lan_to_wan = { src = 'lan', dest = 'wan' },
    },
  },
  routing = {
    routes = {
      { interface = 'lan', target = '10.0.0.0/8', gateway = '192.168.10.254' },
    },
  },
  wan = {},
  shaping = {},
  vpn = {},
  diagnostics = {},
}

fibers.run(function(_scope)
  local provider, perr = provider_loader.new({
    provider = 'openwrt',
    confdir = conf,
    savedir = save,
    debounce_s = 0.01,
    run_cmd = function(argv)
      restarts[#restarts + 1] = table.concat(argv, ' ')
      return true, nil
    end,
  }, {})
  assert(provider, perr)

  local valid = perform(provider:validate_op({ intent = intent }))
  assert(valid and valid.ok == true, 'validate failed: ' .. tostring(valid and valid.err))

  local plan = perform(provider:plan_op({ intent = intent }))
  assert(plan and plan.ok == true, 'plan failed: ' .. tostring(plan and plan.err))
  assert(plan.plan.packages.network.changes > 0, 'network plan should have changes')
  assert(plan.plan.packages.dhcp.changes > 0, 'dhcp plan should have changes')
  assert(plan.plan.packages.firewall.changes > 0, 'firewall plan should have changes')

  local result = perform(provider:apply_op({ intent = intent }))
  assert(result and result.ok == true, 'apply failed: ' .. tostring(result and result.err))
  eq(result.backend, 'openwrt', 'backend')
  eq(result.intent_rev, 101, 'intent_rev')

  provider:terminate('test complete')
end)

eq(#restarts, 3, 'restart command count')
eq(restarts[1], '/etc/init.d/network reload', 'network reload')
eq(restarts[2], '/etc/init.d/dnsmasq restart', 'dnsmasq restart')
eq(restarts[3], '/etc/init.d/firewall restart', 'firewall restart')

local c = assert(uci.cursor(conf, save))
for _, pkg in ipairs({ 'network', 'dhcp', 'firewall' }) do
  if type(c.load) == 'function' then pcall(function() c:load(pkg) end) end
end

eq(c:get('network', 'dev_lan'), 'device', 'network.dev_lan type')
eq(c:get('network', 'dev_lan', 'name'), 'br-lan', 'bridge name')
eq(c:get('network', 'dev_lan', 'type'), 'bridge', 'bridge device type')
assert_list(c:get('network', 'dev_lan', 'ports'), { 'eth0', 'eth1' }, 'bridge ports')

eq(c:get('network', 'lan'), 'interface', 'network.lan type')
eq(c:get('network', 'lan', 'proto'), 'static', 'lan proto')
eq(c:get('network', 'lan', 'device'), 'br-lan', 'lan device')
eq(c:get('network', 'lan', 'ipaddr'), '192.168.10.1', 'lan ipaddr')
eq(c:get('network', 'lan', 'netmask'), '255.255.255.0', 'lan netmask')

eq(c:get('network', 'wan'), 'interface', 'network.wan type')
eq(c:get('network', 'wan', 'proto'), 'dhcp', 'wan proto')
eq(c:get('network', 'wan', 'device'), 'eth2', 'wan device')
eq(c:get('network', 'wan', 'peerdns'), '0', 'wan peerdns')
eq(c:get('network', 'wan', 'metric'), '10', 'wan metric')

eq(c:get('network', 'route_1'), 'route', 'route type')
eq(c:get('network', 'route_1', 'interface'), 'lan', 'route interface')
eq(c:get('network', 'route_1', 'target'), '10.0.0.0/8', 'route target')
eq(c:get('network', 'route_1', 'gateway'), '192.168.10.254', 'route gateway')

eq(c:get('dhcp', 'dnsmasq'), 'dnsmasq', 'dnsmasq type')
assert_list(c:get('dhcp', 'dnsmasq', 'server'), { '1.1.1.1', '8.8.8.8' }, 'dns upstreams')
eq(c:get('dhcp', 'lan'), 'dhcp', 'dhcp.lan type')
eq(c:get('dhcp', 'lan', 'interface'), 'lan', 'dhcp interface')
eq(c:get('dhcp', 'lan', 'start'), '20', 'dhcp start')
eq(c:get('dhcp', 'lan', 'limit'), '50', 'dhcp limit')
eq(c:get('dhcp', 'lan', 'leasetime'), '6h', 'dhcp leasetime')

eq(c:get('firewall', 'defaults'), 'defaults', 'firewall defaults type')
eq(c:get('firewall', 'defaults', 'input'), 'REJECT', 'firewall defaults input')
eq(c:get('firewall', 'zone_lan'), 'zone', 'lan zone type')
eq(c:get('firewall', 'zone_lan', 'name'), 'lan', 'lan zone name')
assert_list(c:get('firewall', 'zone_lan', 'network'), { 'lan' }, 'lan zone networks')
eq(c:get('firewall', 'zone_wan', 'masq'), '1', 'wan zone masq')
eq(c:get('firewall', 'zone_wan', 'mtu_fix'), '1', 'wan zone mtu_fix')
eq(c:get('firewall', 'fwd_lan_to_wan_1'), 'forwarding', 'forwarding type')
eq(c:get('firewall', 'fwd_lan_to_wan_1', 'src'), 'lan', 'forwarding src')
eq(c:get('firewall', 'fwd_lan_to_wan_1', 'dest'), 'wan', 'forwarding dest')

print('openwrt network provider minimal apply: ok')
LUA

"$SSH" "rm -rf '$REMOTE'; mkdir -p '$REMOTE'"
"$SCP_TO" "$ROOT_DIR/src" "$REMOTE/src"
"$SCP_TO" "$ROOT_DIR/vendor" "$REMOTE/vendor"
"$SCP_TO" "$WORK/run_openwrt_network_provider_apply.lua" "$REMOTE/run_openwrt_network_provider_apply.lua"
"$SSH" "cd '$REMOTE' && lua ./run_openwrt_network_provider_apply.lua"
