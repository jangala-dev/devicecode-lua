#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(CDPATH= cd -- "$VM_DIR/../../.." && pwd)"
SSH="$VM_DIR/scripts/ssh"
SCP_TO="$VM_DIR/scripts/scp-to"
REMOTE="/tmp/devicecode-network-provider-segment-trunk-test"
WORK="$VM_DIR/work/network-provider-segment-trunk-test"

mkdir -p "$WORK"
cat > "$WORK/run_openwrt_network_provider_segment_trunk.lua" <<'LUA'
package.path = table.concat({
  './src/?.lua', './src/?/init.lua',
  './vendor/lua-fibers/src/?.lua', './vendor/lua-fibers/src/?/init.lua',
  './vendor/lua-bus/src/?.lua', './vendor/lua-bus/src/?/init.lua',
  './vendor/lua-trie/src/?.lua', './vendor/lua-trie/src/?/init.lua',
  package.path,
}, ';')

local fibers = require 'fibers'
local uci = require 'uci'
local provider_loader = require 'services.hal.backends.network.provider'
local names_mod = require 'services.hal.backends.network.providers.openwrt.names'
local perform = fibers.perform

local function fail(msg) error(msg, 2) end
local function eq(a, b, msg)
  if a ~= b then fail((msg or 'values differ') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end
end
local function mkdir_p(path)
  local ok = os.execute("mkdir -p '" .. path .. "'")
  if ok ~= true and ok ~= 0 then fail('mkdir failed for ' .. path) end
end
local function assert_list_contains(list, value, label)
  if type(list) ~= 'table' then fail((label or 'list') .. ' should be a table') end
  for i = 1, #list do if list[i] == value then return true end end
  fail((label or 'list') .. ' missing ' .. tostring(value))
end

local tmp = '/tmp/dc-network-provider-segment-trunk'
os.execute("rm -rf '" .. tmp .. "'")
local conf, save = tmp .. '/conf', tmp .. '/save'
mkdir_p(conf); mkdir_p(save)
for _, pkg in ipairs({ 'network', 'dhcp', 'firewall', 'mwan3' }) do
  local f = assert(io.open(conf .. '/' .. pkg, 'w'))
  f:write('# devicecode segment trunk test\n')
  f:close()
end

local restarts = {}
local shaper_cmds, shaper_batches = {}, {}
local provider = assert(provider_loader.new({
  provider = 'openwrt',
  confdir = conf,
  savedir = save,
  debounce_s = 0.01,
  platform = { segment_trunk = { ifname = 'eth0', protected = true } },
  run_cmd = function(argv) restarts[#restarts + 1] = table.concat(argv, ' '); return true, nil end,
  shaper_run_cmd = function(argv)
    local line = table.concat(argv, ' ')
    shaper_cmds[#shaper_cmds + 1] = line
    if argv[1] == 'tc' and argv[2] == '-batch' and type(argv[3]) == 'string' then
      local f = io.open(argv[3], 'r')
      if f then shaper_batches[#shaper_batches + 1] = f:read('*a') or ''; f:close() end
    end
    return true, nil
  end,
}, {}))

local intent = {
  schema = 'devicecode.net.intent/1',
  rev = 410,
  generation = 4,
  policies = {
    vlan = {
      reserved = { mgmt = 10, switch_control = 11, fabric = 12 },
      ranges = { service = { from = 100, to = 199 } },
    },
  },
  segments = {
    mgmt = {
      kind = 'system', protected = true, user_editable = false,
      vlan = { id = 10, reserved = 'mgmt' },
      addressing = { ipv4 = { mode = 'static', cidr = '192.168.8.1/24' } },
      firewall = { zone = 'mgmt' },
      dhcp = { enabled = false },
    },
    switch_control = {
      kind = 'system', protected = true, user_editable = false,
      vlan = { id = 11, reserved = 'switch_control' },
      addressing = { ipv4 = { mode = 'static', cidr = '192.168.11.1/24' } },
      firewall = { zone = 'system' },
      dhcp = { enabled = false },
    },
    fabric = {
      kind = 'system', protected = true, user_editable = false,
      vlan = { id = 12, reserved = 'fabric' },
      addressing = { ipv4 = { mode = 'static', cidr = '192.168.12.1/24' } },
      firewall = { zone = 'system' },
      dhcp = { enabled = false },
    },
    lan = {
      kind = 'user', vlan = { id = 100 },
      addressing = { ipv4 = { mode = 'static', cidr = '192.168.100.1/24' } },
      dhcp = { enabled = true, start = 20, limit = 50, leasetime = '12h' },
      firewall = { zone = 'lan' },
      shaping = { profile = 'restricted' },
    },
    guest = {
      kind = 'guest', vlan = { id = 101 },
      addressing = { ipv4 = { mode = 'static', cidr = '192.168.101.1/24' } },
      dhcp = { enabled = true, start = 50, limit = 100, leasetime = '6h' },
      firewall = { zone = 'guest' },
    },
    iot = {
      kind = 'user', l2 = { mode = 'direct' }, vlan = { id = 102 },
      addressing = { ipv4 = { mode = 'static', cidr = '192.168.102.1/24' } },
      dhcp = { enabled = false },
      firewall = { zone = 'lan' },
      shaping = { profile = 'restricted_iot' },
    },
  },
  interfaces = {},
  dns = { enabled = true, upstreams = { '1.1.1.1' } },
  dhcp = {},
  firewall = {
    zones = {
      mgmt = { input = 'ACCEPT', output = 'ACCEPT', forward = 'REJECT' },
      system = { input = 'ACCEPT', output = 'ACCEPT', forward = 'REJECT' },
      lan = { input = 'ACCEPT', output = 'ACCEPT', forward = 'REJECT' },
      guest = { input = 'REJECT', output = 'ACCEPT', forward = 'REJECT' },
    },
  },
  routing = {}, wan = {}, shaping = { enabled = true, profiles = {
    restricted = { egress = { enabled = true, host_rate = '2mbit', hosts = { ['192.168.100.2'] = { rate = '1mbit' } } } },
    restricted_iot = { egress = { enabled = true, host_rate = '2mbit', hosts = { ['192.168.102.2'] = { rate = '1mbit' } } } },
  } }, vpn = {}, diagnostics = {},
}

local name_ctx = assert(names_mod.allocate(intent))

fibers.run(function()
  local valid = perform(provider:validate_op({ intent = intent }))
  assert(valid and valid.ok == true, 'validate failed: ' .. tostring(valid and valid.err))
  local plan = perform(provider:plan_op({ intent = intent }))
  assert(plan and plan.ok == true, 'plan failed: ' .. tostring(plan and plan.err))
  assert(plan.plan.packages.network.sections >= 10, 'segment trunk should create network sections')
  local result = perform(provider:apply_op({ intent = intent }))
  assert(result and result.ok == true, 'apply failed: ' .. tostring(result and result.err))
  provider:terminate('test complete')
end)

if #shaper_cmds == 0 then fail('shaper commands expected for shaped trunk segment') end
local shaper_text = table.concat(shaper_cmds, '\n') .. '\n' .. table.concat(shaper_batches, '\n')
if not shaper_text:find('br%-lan') then fail('bridged trunk segment shaping should target bridge data device br-lan, got: ' .. shaper_text) end
if shaper_text:find('dev vl%-lan') then fail('bridged trunk segment shaping must not target VLAN member device vl-lan') end
if shaper_text:find('eth0%.100') then fail('trunk segment shaping must not target legacy eth0.100') end
if not shaper_text:find('ifb_br_lan') then fail('bridged trunk segment ingress IFB should be derived from br-lan') end
if not shaper_text:find('vl%-iot') then fail('direct trunk segment shaping should target VLAN data device vl-iot, got: ' .. shaper_text) end
if not shaper_text:find('ifb_vl_iot') then fail('direct trunk segment ingress IFB should be derived from vl-iot') end

local c = assert(uci.cursor(conf, save))
for _, pkg in ipairs({ 'network', 'dhcp', 'firewall' }) do if type(c.load) == 'function' then pcall(function() c:load(pkg) end) end end

local function all(pkg)
  if type(c.load) == 'function' then pcall(function() c:load(pkg) end) end
  return c:get_all(pkg) or {}
end
local function section_by_name(pkg, section, stype)
  local sec = all(pkg)[section]
  if type(sec) ~= 'table' then fail('section not found: ' .. pkg .. '.' .. tostring(section)) end
  if stype ~= nil and sec['.type'] ~= stype then fail(pkg .. '.' .. tostring(section) .. ' expected type ' .. tostring(stype) .. ', got ' .. tostring(sec['.type'])) end
  return section, sec
end

local function find_firewall_zone(zone_name)
  for name, sec in pairs(all('firewall')) do
    if type(sec) == 'table' and sec['.type'] == 'zone' and sec.name == zone_name then return name, sec end
  end
  fail('firewall zone not found: ' .. tostring(zone_name))
end
local function contains(list, value)
  if type(list) == 'table' then for i = 1, #list do if list[i] == value then return true end end end
  return list == value
end

local expected = {
  mgmt = { vid = '10', cidr_ip = '192.168.8.1', netmask = '255.255.255.0' },
  switch_control = { vid = '11', cidr_ip = '192.168.11.1', netmask = '255.255.255.0' },
  fabric = { vid = '12', cidr_ip = '192.168.12.1', netmask = '255.255.255.0' },
  lan = { vid = '100', cidr_ip = '192.168.100.1', netmask = '255.255.255.0' },
  guest = { vid = '101', cidr_ip = '192.168.101.1', netmask = '255.255.255.0' },
}

local iface_by_seg = {}
for seg, e in pairs(expected) do
  local _vlan_sec, vlan = section_by_name('network', name_ctx:section('dev_vlan', seg), 'device')
  eq(vlan.type, '8021q', seg .. ' vlan device type')
  eq(vlan.ifname, 'eth0', seg .. ' vlan ifname')
  eq(vlan.vid, e.vid, seg .. ' vid')
  assert(#vlan.name <= 14, seg .. ' vlan name length')
  local _br_sec, br = section_by_name('network', name_ctx:section('dev_bridge', seg), 'device')
  eq(br.type, 'bridge', seg .. ' bridge device type')
  assert_list_contains(br.ports, vlan.name, seg .. ' bridge ports')
  assert(#br.name <= 14, seg .. ' bridge name length')
  local ifsec, iface = section_by_name('network', name_ctx:iface(seg), 'interface')
  iface_by_seg[seg] = ifsec
  eq(iface.device, br.name, seg .. ' interface bridge device')
  eq(iface.ipaddr, e.cidr_ip, seg .. ' ipaddr')
  eq(iface.netmask, e.netmask, seg .. ' netmask')
  assert(#ifsec <= 8, seg .. ' logical interface length')
end

local _iot_vlan_sec, iot_vlan = section_by_name('network', name_ctx:section('dev_vlan', 'iot'), 'device')
eq(iot_vlan.type, '8021q', 'iot direct vlan device type')
eq(iot_vlan.ifname, 'eth0', 'iot direct vlan ifname')
eq(iot_vlan.vid, '102', 'iot direct vid')
local _iot_ifsec, iot_iface = section_by_name('network', name_ctx:iface('iot'), 'interface')
eq(iot_iface.device, iot_vlan.name, 'direct segment interface should use VLAN device')
eq(iot_iface.ipaddr, '192.168.102.1', 'iot direct ipaddr')
eq(iot_iface.netmask, '255.255.255.0', 'iot direct netmask')
if all('network')[name_ctx:section('dev_bridge', 'iot')] ~= nil then fail('direct segment should not create bridge device') end

local _dhcp_lan_sec, dhcp_lan = section_by_name('dhcp', name_ctx:section('dhcp', 'lan'), 'dhcp')
local _dhcp_guest_sec, dhcp_guest = section_by_name('dhcp', name_ctx:section('dhcp', 'guest'), 'dhcp')
local _dhcp_mgmt_sec, dhcp_mgmt = section_by_name('dhcp', name_ctx:section('dhcp', 'mgmt'), 'dhcp')
eq(dhcp_lan.interface, iface_by_seg.lan, 'lan dhcp interface')
eq(dhcp_guest.interface, iface_by_seg.guest, 'guest dhcp interface')
eq(dhcp_mgmt.ignore, '1', 'mgmt dhcp ignored')

local _zone_lan_sec, zone_lan = find_firewall_zone('lan')
local _zone_guest_sec, zone_guest = find_firewall_zone('guest')
local _zone_system_sec, zone_system = find_firewall_zone('system')
assert_list_contains(zone_lan.network, iface_by_seg.lan, 'lan zone network')
assert_list_contains(zone_guest.network, iface_by_seg.guest, 'guest zone network')
assert_list_contains(zone_system.network, iface_by_seg.switch_control, 'system zone network')
assert_list_contains(zone_system.network, iface_by_seg.fabric, 'system zone network')

print('openwrt network provider segment trunk: ok')
LUA

"$SSH" "rm -rf '$REMOTE'; mkdir -p '$REMOTE'"
"$SCP_TO" "$ROOT_DIR/src" "$REMOTE/src"
"$SCP_TO" "$ROOT_DIR/vendor" "$REMOTE/vendor"
"$SCP_TO" "$WORK/run_openwrt_network_provider_segment_trunk.lua" "$REMOTE/run_openwrt_network_provider_segment_trunk.lua"
"$SSH" "cd '$REMOTE' && lua ./run_openwrt_network_provider_segment_trunk.lua"
