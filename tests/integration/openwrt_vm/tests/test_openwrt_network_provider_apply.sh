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
local sleep = require 'fibers.sleep'
local bus = require 'bus'
local trie = require 'trie'
local uci = require 'uci'
local provider_loader = require 'services.hal.backends.network.provider'
local names_mod = require 'services.hal.backends.network.providers.openwrt.names'

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

local function wait_until(pred, timeout_s, label)
  local deadline = fibers.now() + (timeout_s or 1)
  while fibers.now() < deadline do
    if pred() then return true end
    perform(sleep.sleep_op(0.01))
  end
  if pred() then return true end
  fail(label or 'condition was not satisfied before timeout')
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
      dns = { local_server = true, domain = 'bigbox.home', host_files = { 'ads' } },
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
      addressing = { ipv4 = { mode = 'dhcp', peerdns = false } },
    },
  },
  dns = {
    enabled = true,
    domain = 'bigbox.home',
    upstreams = { '1.1.1.1', '8.8.8.8' },
    cache = { size = 1000 },
    host_files = { base_dir = '/tmp/devicecode-dns-hosts', sources = { ads = { file = 'ads.hosts' } } },
    records = { router = { name = 'config.bigbox.home', address = '192.168.10.1' }, bad = { name = 'bad.bigbox.home', address = '$UNIFI-ADDRESS' } },
  },
  dhcp = { defaults = { authoritative = true } },
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
  wan = { enabled = true, members = { wan = { interface = 'wan', mwan_metric = 1, weight = 1 } } },
  
  vpn = {},
  diagnostics = {},
}

local name_ctx = assert(names_mod.allocate(intent))

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
  assert(result.activation == nil, 'provider activation should be synchronous for structural network apply')
  eq(#restarts, 4, 'activation command count')

  provider:terminate('test complete')
end)

eq(#restarts, 4, 'restart command count')
eq(restarts[1], '/etc/init.d/network reload', 'network reload')
eq(restarts[2], '/etc/init.d/dnsmasq restart', 'dnsmasq restart')
eq(restarts[3], '/etc/init.d/firewall restart', 'firewall restart')
eq(restarts[4], '/etc/init.d/mwan3 restart', 'mwan3 restart')

local c = assert(uci.cursor(conf, save))
for _, pkg in ipairs({ 'network', 'dhcp', 'firewall' }) do
  if type(c.load) == 'function' then pcall(function() c:load(pkg) end) end
end

local function all(pkg)
  if type(c.load) == 'function' then pcall(function() c:load(pkg) end) end
  return c:get_all(pkg) or {}
end

local function list_contains(v, item)
  if type(v) == 'table' then
    for i = 1, #v do if v[i] == item then return true end end
    return false
  end
  return v == item
end

local function section_by_name(pkg, section, stype)
  local sec = all(pkg)[section]
  if type(sec) ~= 'table' then fail('section not found in ' .. pkg .. ': ' .. tostring(section)) end
  if stype ~= nil and sec['.type'] ~= stype then fail(pkg .. '.' .. tostring(section) .. ' expected type ' .. tostring(stype) .. ', got ' .. tostring(sec['.type'])) end
  return section, sec
end

local function assert_no_devicecode_metadata()
  for _, pkg in ipairs({ 'network', 'dhcp', 'firewall', 'mwan3' }) do
    for name, sec in pairs(all(pkg)) do
      if type(sec) == 'table' then
        for _, opt in ipairs({ 'devicecode_managed', 'devicecode_owner', 'devicecode_semantic_id', 'devicecode_role' }) do
          if sec[opt] ~= nil then fail('unexpected UCI metadata ' .. pkg .. '.' .. tostring(name) .. '.' .. opt) end
        end
      end
    end
  end
end

local function find_firewall_zone(zone_name)
  for name, sec in pairs(all('firewall')) do
    if type(sec) == 'table' and sec['.type'] == 'zone' and sec.name == zone_name then
      return name, sec
    end
  end
  fail('firewall zone not found: ' .. tostring(zone_name))
end

local function find_firewall_forwarding(src, dest)
  for name, sec in pairs(all('firewall')) do
    if type(sec) == 'table' and sec['.type'] == 'forwarding' and sec.src == src and sec.dest == dest then
      return name, sec
    end
  end
  fail('firewall forwarding not found: ' .. tostring(src) .. ' -> ' .. tostring(dest))
end

local lan_bridge_sec, lan_bridge = section_by_name('network', name_ctx:section('dev_bridge', 'lan'), 'device')
eq(lan_bridge.name, 'br-lan', 'bridge name')
eq(lan_bridge.type, 'bridge', 'bridge device type')
assert_list(lan_bridge.ports, { 'eth0', 'eth1' }, 'bridge ports')

local _lan_if_sec, lan_if = section_by_name('network', name_ctx:iface('lan'), 'interface')
eq(_lan_if_sec, 'lan', 'lan generated interface remains readable')
eq(lan_if.proto, 'static', 'lan proto')
eq(lan_if.device, 'br-lan', 'lan device')
eq(lan_if.ipaddr, '192.168.10.1', 'lan ipaddr')
eq(lan_if.netmask, '255.255.255.0', 'lan netmask')

local _wan_if_sec, wan_if = section_by_name('network', name_ctx:iface('wan'), 'interface')
eq(_wan_if_sec, 'wan', 'wan generated interface remains readable')
eq(wan_if.proto, 'dhcp', 'wan proto')
eq(wan_if.device, 'eth2', 'wan device')
eq(wan_if.peerdns, '0', 'wan peerdns')
eq(wan_if.defaultroute, nil, 'wan defaultroute should use OpenWrt default')
eq(wan_if.metric, '11', 'wan auto route metric')

local _route_sec, route = section_by_name('network', name_ctx:section('route', '1'), 'route')
eq(route.interface, 'lan', 'route interface')
eq(route.target, '10.0.0.0/8', 'route target')
eq(route.gateway, '192.168.10.254', 'route gateway')

local dns_sec, dns = nil, nil
for name, sec in pairs(all('dhcp')) do
  if type(sec) == 'table' and sec['.type'] == 'dnsmasq' and list_contains(sec.addnhosts, '/tmp/devicecode-dns-hosts/ads.hosts') then dns_sec, dns = name, sec; break end
end
if not dns then fail('ads dnsmasq instance not found') end
assert_list(dns.server, { '1.1.1.1', '8.8.8.8' }, 'dns upstreams')
eq(dns.cachesize, '1000', 'dns cache size')
local addnhosts = dns.addnhosts
if type(addnhosts) == 'table' then eq(addnhosts[1], '/tmp/devicecode-dns-hosts/ads.hosts', 'dns host file') else eq(addnhosts, '/tmp/devicecode-dns-hosts/ads.hosts', 'dns host file') end
local addresses = dns.address
local address_s = type(addresses) == 'table' and table.concat(addresses, ' ') or tostring(addresses)
if not address_s:find('/config.bigbox.home/192.168.10.1', 1, true) then fail('dns record missing: ' .. address_s) end
if address_s:find('$UNIFI-ADDRESS', 1, true) then fail('invalid dns record was emitted: ' .. address_s) end

local _dhcp_sec, dhcp_lan = section_by_name('dhcp', name_ctx:section('dhcp', 'lan'), 'dhcp')
eq(dhcp_lan.interface, 'lan', 'dhcp interface')
eq(dhcp_lan.instance, dns_sec, 'dhcp instance')
eq(dhcp_lan.start, '20', 'dhcp start')
eq(dhcp_lan.limit, '50', 'dhcp limit')
eq(dhcp_lan.leasetime, '6h', 'dhcp leasetime')

local _fw_defaults, fw_defaults = section_by_name('firewall', 'defaults', 'defaults')
eq(fw_defaults.input, 'REJECT', 'firewall defaults input')
local _zone_lan_sec, zone_lan = find_firewall_zone('lan')
eq(zone_lan.name, 'lan', 'lan zone name')
assert_list(zone_lan.network, { 'lan' }, 'lan zone networks')
local _zone_wan_sec, zone_wan = find_firewall_zone('wan')
eq(zone_wan.masq, '1', 'wan zone masq')
eq(zone_wan.mtu_fix, '1', 'wan zone mtu_fix')
local _fwd_sec, fwd = find_firewall_forwarding('lan', 'wan')
eq(fwd.src, 'lan', 'forwarding src')
eq(fwd.dest, 'wan', 'forwarding dest')

assert_no_devicecode_metadata()
print('openwrt network provider minimal apply: ok')
LUA

"$SSH" "rm -rf '$REMOTE'; mkdir -p '$REMOTE'"
"$SCP_TO" "$ROOT_DIR/src" "$REMOTE/src"
"$SCP_TO" "$ROOT_DIR/vendor" "$REMOTE/vendor"
"$SCP_TO" "$WORK/run_openwrt_network_provider_apply.lua" "$REMOTE/run_openwrt_network_provider_apply.lua"
"$SSH" "cd '$REMOTE' && lua ./run_openwrt_network_provider_apply.lua"
