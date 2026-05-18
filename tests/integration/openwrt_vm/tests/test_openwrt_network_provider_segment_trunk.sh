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
local provider = assert(provider_loader.new({
  provider = 'openwrt',
  confdir = conf,
  savedir = save,
  debounce_s = 0.01,
  platform = { segment_trunk = { ifname = 'eth0', protected = true } },
  run_cmd = function(argv) restarts[#restarts + 1] = table.concat(argv, ' '); return true, nil end,
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
    },
    guest = {
      kind = 'guest', vlan = { id = 101 },
      addressing = { ipv4 = { mode = 'static', cidr = '192.168.101.1/24' } },
      dhcp = { enabled = true, start = 50, limit = 100, leasetime = '6h' },
      firewall = { zone = 'guest' },
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
  routing = {}, wan = {}, shaping = {}, vpn = {}, diagnostics = {},
}

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

local c = assert(uci.cursor(conf, save))
for _, pkg in ipairs({ 'network', 'dhcp', 'firewall' }) do if type(c.load) == 'function' then pcall(function() c:load(pkg) end) end end

local expected = {
  mgmt = { vid = '10', cidr_ip = '192.168.8.1', netmask = '255.255.255.0' },
  switch_control = { vid = '11', cidr_ip = '192.168.11.1', netmask = '255.255.255.0' },
  fabric = { vid = '12', cidr_ip = '192.168.12.1', netmask = '255.255.255.0' },
  lan = { vid = '100', cidr_ip = '192.168.100.1', netmask = '255.255.255.0' },
  guest = { vid = '101', cidr_ip = '192.168.101.1', netmask = '255.255.255.0' },
}

for seg, e in pairs(expected) do
  local devsec = 'dev_seg_' .. seg
  eq(c:get('network', devsec), 'device', devsec .. ' type')
  eq(c:get('network', devsec, 'type'), '8021q', devsec .. ' device type')
  eq(c:get('network', devsec, 'ifname'), 'eth0', devsec .. ' ifname')
  eq(c:get('network', devsec, 'vid'), e.vid, devsec .. ' vid')
  eq(c:get('network', devsec, 'name'), 'eth0.' .. e.vid, devsec .. ' name')
  eq(c:get('network', seg), 'interface', seg .. ' interface type')
  eq(c:get('network', seg, 'device'), 'eth0.' .. e.vid, seg .. ' device')
  eq(c:get('network', seg, 'ipaddr'), e.cidr_ip, seg .. ' ipaddr')
  eq(c:get('network', seg, 'netmask'), e.netmask, seg .. ' netmask')
end

eq(c:get('dhcp', 'lan'), 'dhcp', 'lan dhcp type')
eq(c:get('dhcp', 'guest'), 'dhcp', 'guest dhcp type')
eq(c:get('dhcp', 'mgmt', 'ignore'), '1', 'mgmt dhcp ignored')

assert_list_contains(c:get('firewall', 'zone_lan', 'network'), 'lan', 'lan zone network')
assert_list_contains(c:get('firewall', 'zone_guest', 'network'), 'guest', 'guest zone network')
assert_list_contains(c:get('firewall', 'zone_system', 'network'), 'switch_control', 'system zone network')
assert_list_contains(c:get('firewall', 'zone_system', 'network'), 'fabric', 'system zone network')

print('openwrt network provider segment trunk: ok')
LUA

"$SSH" "rm -rf '$REMOTE'; mkdir -p '$REMOTE'"
"$SCP_TO" "$ROOT_DIR/src" "$REMOTE/src"
"$SCP_TO" "$ROOT_DIR/vendor" "$REMOTE/vendor"
"$SCP_TO" "$WORK/run_openwrt_network_provider_segment_trunk.lua" "$REMOTE/run_openwrt_network_provider_segment_trunk.lua"
"$SSH" "cd '$REMOTE' && lua ./run_openwrt_network_provider_segment_trunk.lua"
