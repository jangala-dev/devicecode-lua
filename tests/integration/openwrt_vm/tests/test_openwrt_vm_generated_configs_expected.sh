#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(CDPATH= cd -- "$VM_DIR/../../.." && pwd)"
SSH="$VM_DIR/scripts/ssh"
SCP_TO="$VM_DIR/scripts/scp-to"
REMOTE="/tmp/devicecode-vm-generated-config-expected-test"

DEVICECODE_VM_MWAN_CONFIG_FORCE=1 "$SCRIPT_DIR/setup_devicecode_vm_mwan_generated_config.sh"

mkdir -p "$VM_DIR/work"
cat > "$VM_DIR/work/run_devicecode_vm_generated_config_expected.lua" <<'LUA'
package.path = table.concat({
  './src/?.lua', './src/?/init.lua',
  './vendor/lua-fibers/src/?.lua', './vendor/lua-fibers/src/?/init.lua',
  './vendor/lua-bus/src/?.lua', './vendor/lua-bus/src/?/init.lua',
  './vendor/lua-trie/src/?.lua', './vendor/lua-trie/src/?/init.lua',
  './fixtures/?.lua',
  package.path,
}, ';')

local uci = require 'uci'
local names_mod = require 'services.hal.backends.network.providers.openwrt.names'
local vm_intent = require 'devicecode_vm_mwan_intent'

local function fail(msg) error(msg, 2) end
local function eq(a, b, msg) if a ~= b then fail((msg or 'values differ') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function assert_true(v, msg) if not v then fail(msg or 'assertion failed') end end
local function list_values(v)
  if type(v) == 'table' then return v end
  if v == nil then return {} end
  return { v }
end
local function sorted(v)
  local out = {}
  for i = 1, #(v or {}) do out[i] = tostring(v[i]) end
  table.sort(out)
  return out
end
local function eq_list(v, expected, msg)
  local a, b = sorted(list_values(v)), sorted(expected)
  if #a ~= #b then fail((msg or 'list length') .. ': expected ' .. table.concat(b, ',') .. ', got ' .. table.concat(a, ',')) end
  for i = 1, #b do if a[i] ~= b[i] then fail((msg or 'list') .. ': expected ' .. table.concat(b, ',') .. ', got ' .. table.concat(a, ',')) end end
end
local function section(c, pkg, name, typ)
  local sec = c:get_all(pkg, name)
  if type(sec) ~= 'table' then fail('missing section ' .. pkg .. '.' .. tostring(name)) end
  if typ then eq(sec['.type'], typ, pkg .. '.' .. name .. ' type') end
  return sec
end
local function find_section(c, pkg, typ, pred, label)
  local all = c:get_all(pkg) or {}
  for name, sec in pairs(all) do
    if type(sec) == 'table' and sec['.type'] == typ and pred(name, sec) then return name, sec end
  end
  fail('missing ' .. (label or (pkg .. ' ' .. typ)))
end
local function assert_no_metadata(c)
  for _, pkg in ipairs({ 'network', 'dhcp', 'firewall', 'mwan3' }) do
    for name, sec in pairs(c:get_all(pkg) or {}) do
      if type(sec) == 'table' then
        for _, opt in ipairs({ 'devicecode_managed', 'devicecode_owner', 'devicecode_semantic_id', 'devicecode_role' }) do
          if sec[opt] ~= nil then fail('unexpected metadata ' .. pkg .. '.' .. tostring(name) .. '.' .. opt) end
        end
      end
    end
  end
end
local function assert_no_legacy_modem_names(c)
  for _, pkg in ipairs({ 'network', 'dhcp', 'firewall', 'mwan3' }) do
    for name, sec in pairs(c:get_all(pkg) or {}) do
      local blob = tostring(name)
      if type(sec) == 'table' then
        for k, v in pairs(sec) do
          blob = blob .. ' ' .. tostring(k)
          if type(v) == 'table' then blob = blob .. ' ' .. table.concat(v, ' ') else blob = blob .. ' ' .. tostring(v) end
        end
      end
      if blob:find('mdm0', 1, true) or blob:find('mdm1', 1, true) then fail('legacy modem name leaked in ' .. pkg .. '.' .. tostring(name)) end
    end
  end
end

local intent = vm_intent.intent()
local name_ctx = assert(names_mod.allocate(intent))
local c = assert(uci.cursor('/etc/config'))
for _, pkg in ipairs({ 'network', 'dhcp', 'firewall', 'mwan3' }) do if type(c.load) == 'function' then pcall(function() c:load(pkg) end) end end

local loopback = section(c, 'network', 'loopback', 'interface')
eq(loopback.device, 'lo', 'loopback device')
eq(loopback.proto, 'static', 'loopback proto')
section(c, 'network', 'globals', 'globals')

local br = section(c, 'network', name_ctx:section('dev_bridge', 'lan'), 'device')
eq(br.name, 'br-lan', 'LAN bridge name')
eq(br.type, 'bridge', 'LAN bridge type')
eq_list(br.ports, { 'eth0' }, 'LAN bridge ports')
local lan = section(c, 'network', name_ctx:iface('lan'), 'interface')
eq(lan.proto, 'static', 'LAN proto')
eq(lan.device, 'br-lan', 'LAN device')
eq(lan.ipaddr, '192.168.1.1', 'LAN ipaddr')
eq(lan.netmask, '255.255.255.0', 'LAN netmask')

for _, wan in ipairs(vm_intent.wans) do
  local sec = section(c, 'network', name_ctx:iface(wan.id), 'interface')
  eq(sec.proto, 'dhcp', wan.id .. ' proto')
  eq(sec.device, wan.device, wan.id .. ' device')
  eq(sec.peerdns, '0', wan.id .. ' peerdns')
  eq(sec.metric, tostring(wan.route_metric), wan.id .. ' generated route metric')
  eq(sec.defaultroute, nil, wan.id .. ' defaultroute should use OpenWrt default')

  local dh = section(c, 'dhcp', name_ctx:section('dhcp', wan.id), 'dhcp')
  eq(dh.interface, name_ctx:iface(wan.id), wan.id .. ' DHCP interface')
  eq(dh.ignore, '1', wan.id .. ' DHCP ignore')

  local mw_if = section(c, 'mwan3', name_ctx:mwan_iface(wan.id), 'interface')
  eq(mw_if.enabled, '1', wan.id .. ' mwan enabled')
  eq(mw_if.family, 'ipv4', wan.id .. ' mwan family')
  eq_list(mw_if.track_ip, { wan.gateway }, wan.id .. ' track_ip')
  eq(mw_if.initial_state, 'online', wan.id .. ' mwan initial_state')
  eq(mw_if.reliability, '1', wan.id .. ' reliability')

  local member_name, member = find_section(c, 'mwan3', 'member', function(_, s) return s.interface == name_ctx:mwan_iface(wan.id) end, wan.id .. ' mwan member')
  eq(member.metric, '1', wan.id .. ' mwan policy metric')
  eq(member.weight, tostring(wan.weight), wan.id .. ' mwan weight')
end

local dh_lan = section(c, 'dhcp', name_ctx:section('dhcp', 'lan'), 'dhcp')
eq(dh_lan.interface, 'lan', 'LAN DHCP interface')
eq(dh_lan.start, '100', 'LAN DHCP start')
eq(dh_lan.limit, '150', 'LAN DHCP limit')
find_section(c, 'dhcp', 'dnsmasq', function(_, s)
  return s.domain == 'vm.bigbox.test' and tostring(s.cachesize) == '1000'
end, 'vm dnsmasq')

local _, zone_lan = find_section(c, 'firewall', 'zone', function(_, s) return s.name == 'lan' end, 'LAN firewall zone')
eq_list(zone_lan.network, { 'lan' }, 'LAN firewall networks')
local _, zone_wan = find_section(c, 'firewall', 'zone', function(_, s) return s.name == 'wan' end, 'WAN firewall zone')
eq(zone_wan.masq, '1', 'WAN zone masq')
eq(zone_wan.mtu_fix, '1', 'WAN zone mtu_fix')
eq_list(zone_wan.network, { 'wan', 'wanb', 'wanc' }, 'WAN firewall networks')
find_section(c, 'firewall', 'forwarding', function(_, s) return s.src == 'lan' and s.dest == 'wan' end, 'LAN to WAN forwarding')

local policy = section(c, 'mwan3', name_ctx:mwan_policy('balanced'), 'policy')
eq(policy.last_resort, 'unreachable', 'balanced last_resort')
local expected_members = {}
for _, wan in ipairs(vm_intent.wans) do
  local member_name = (find_section(c, 'mwan3', 'member', function(_, s) return s.interface == name_ctx:mwan_iface(wan.id) end, wan.id .. ' member'))
  expected_members[#expected_members + 1] = member_name
end
eq_list(policy.use_member, expected_members, 'balanced policy members')
local https = section(c, 'mwan3', name_ctx:mwan_rule('https'), 'rule')
eq(https.proto, 'tcp', 'https sticky proto')
eq(https.dest_port, '443', 'https sticky dest_port')
eq(https.family, 'ipv4', 'https sticky family')
eq(https.sticky, '1', 'https sticky flag')
eq(https.use_policy, name_ctx:mwan_policy('balanced'), 'https sticky policy')
local rule = section(c, 'mwan3', name_ctx:mwan_rule('default_rule_v4'), 'rule')
eq(rule.dest_ip, '0.0.0.0/0', 'default rule dest')
eq(rule.family, 'ipv4', 'default rule family')
eq(rule.use_policy, name_ctx:mwan_policy('balanced'), 'default rule policy')

assert_no_metadata(c)
assert_no_legacy_modem_names(c)
print('openwrt VM generated /etc/config files match expected Devicecode shape: ok')
LUA

"$SSH" "rm -rf '$REMOTE'; mkdir -p '$REMOTE/fixtures'"
"$SCP_TO" "$ROOT_DIR/src" "$REMOTE/src"
"$SCP_TO" "$ROOT_DIR/vendor" "$REMOTE/vendor"
"$SCP_TO" "$VM_DIR/fixtures/devicecode_vm_mwan_intent.lua" "$REMOTE/fixtures/devicecode_vm_mwan_intent.lua"
"$SCP_TO" "$VM_DIR/work/run_devicecode_vm_generated_config_expected.lua" "$REMOTE/run_devicecode_vm_generated_config_expected.lua"
"$SSH" "cd '$REMOTE' && lua ./run_devicecode_vm_generated_config_expected.lua"
