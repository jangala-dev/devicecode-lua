#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(CDPATH= cd -- "$VM_DIR/../../.." && pwd)"
SSH="$VM_DIR/scripts/ssh"
SCP_TO="$VM_DIR/scripts/scp-to"
REMOTE="/tmp/devicecode-network-provider-snapshot-test"
WORK="$VM_DIR/work/network-provider-snapshot-test"

mkdir -p "$WORK"

cat > "$WORK/run_openwrt_network_provider_snapshot.lua" <<'LUA'
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

local tmp = '/tmp/dc-network-provider-snapshot'
os.execute("rm -rf '" .. tmp .. "'")
local conf = tmp .. '/conf'
local save = tmp .. '/save'
mkdir_p(conf)
mkdir_p(save)
for _, pkg in ipairs({ 'network', 'dhcp', 'firewall', 'mwan3' }) do
  local f = assert(io.open(conf .. '/' .. pkg, 'w'))
  f:write('# devicecode OpenWrt network provider snapshot test\n')
  f:close()
end

local restarts = {}

local intent = {
  schema = 'devicecode.net.intent/1',
  rev = 202,
  generation = 4,
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

  local result = perform(provider:apply_op({ intent = intent }))
  assert(result and result.ok == true, 'apply failed: ' .. tostring(result and result.err))

  local snapshot = perform(provider:snapshot_op({}))
  assert(snapshot and snapshot.ok == true, 'snapshot failed: ' .. tostring(snapshot and snapshot.err))
  eq(snapshot.backend, 'openwrt', 'snapshot backend')
  assert(type(snapshot.packages) == 'table', 'snapshot should retain raw packages for diagnostics')

  local observed = snapshot.observed
  assert(type(observed) == 'table', 'snapshot.observed should be a table')
  eq(observed.schema, 'devicecode.net.observed/1', 'observed schema')

  eq(observed.interfaces.lan.kind, 'bridge', 'lan kind')
  eq(observed.interfaces.lan.segment, 'lan', 'lan segment')
  assert_list(observed.interfaces.lan.members, { 'eth0', 'eth1' }, 'lan bridge members')
  eq(observed.interfaces.lan.addressing.ipv4.mode, 'static', 'lan ipv4 mode')
  eq(observed.interfaces.lan.addressing.ipv4.cidr, '192.168.10.1/24', 'lan cidr')

  eq(observed.interfaces.wan.kind, 'ethernet', 'wan kind')
  eq(observed.interfaces.wan.segment, 'wan', 'wan segment')
  eq(observed.interfaces.wan.endpoint.ifname, 'eth2', 'wan endpoint')
  eq(observed.interfaces.wan.addressing.ipv4.mode, 'dhcp', 'wan ipv4 mode')
  eq(observed.interfaces.wan.addressing.ipv4.peerdns, false, 'wan peerdns')
  eq(observed.interfaces.wan.addressing.ipv4.metric, 10, 'wan metric')

  eq(observed.segments.lan.firewall.zone, 'lan', 'lan segment zone')
  eq(observed.segments.lan.dhcp.enabled, true, 'lan segment dhcp enabled')
  eq(observed.segments.lan.dhcp.start, 20, 'lan dhcp start')
  eq(observed.segments.lan.dhcp.limit, 50, 'lan dhcp limit')
  eq(observed.segments.lan.dhcp.leasetime, '6h', 'lan dhcp leasetime')
  assert_list(observed.segments.lan.interfaces, { 'lan' }, 'lan segment interfaces')

  assert_list(observed.dns.upstreams, { '1.1.1.1', '8.8.8.8' }, 'dns upstreams')

  eq(observed.firewall.defaults.input, 'REJECT', 'firewall default input')
  eq(observed.firewall.defaults.output, 'ACCEPT', 'firewall default output')
  eq(observed.firewall.defaults.forward, 'REJECT', 'firewall default forward')
  assert_list(observed.firewall.zones.lan.networks, { 'lan' }, 'lan zone networks')
  assert_list(observed.firewall.zones.wan.networks, { 'wan' }, 'wan zone networks')
  eq(observed.firewall.zones.wan.masq, true, 'wan zone masq')
  eq(observed.firewall.zones.wan.mtu_fix, true, 'wan zone mtu_fix')
  eq(observed.firewall.policies.fwd_lan_to_wan_1.src, 'lan', 'forwarding src')
  eq(observed.firewall.policies.fwd_lan_to_wan_1.dest, 'wan', 'forwarding dest')

  eq(#observed.routing.routes, 1, 'route count')
  eq(observed.routing.routes[1].interface, 'lan', 'route interface')
  eq(observed.routing.routes[1].target, '10.0.0.0/8', 'route target')
  eq(observed.routing.routes[1].gateway, '192.168.10.254', 'route gateway')

  provider:terminate('test complete')
end)

eq(#restarts, 3, 'restart command count')

print('openwrt network provider snapshot: ok')
LUA

"$SSH" "rm -rf '$REMOTE'; mkdir -p '$REMOTE'"
"$SCP_TO" "$ROOT_DIR/src" "$REMOTE/src"
"$SCP_TO" "$ROOT_DIR/vendor" "$REMOTE/vendor"
"$SCP_TO" "$WORK/run_openwrt_network_provider_snapshot.lua" "$REMOTE/run_openwrt_network_provider_snapshot.lua"
"$SSH" "cd '$REMOTE' && lua ./run_openwrt_network_provider_snapshot.lua"
