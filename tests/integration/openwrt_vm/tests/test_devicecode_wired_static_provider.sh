#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(CDPATH= cd -- "$VM_DIR/../../.." && pwd)"
SSH="$VM_DIR/scripts/ssh"
SCP_TO="$VM_DIR/scripts/scp-to"
REMOTE="/tmp/devicecode-wired-static-provider-test"
WORK="$VM_DIR/work/wired-static-provider-test"

mkdir -p "$WORK"
cat > "$WORK/run_devicecode_wired_static_provider.lua" <<'LUA'
package.path = table.concat({
  './src/?.lua', './src/?/init.lua',
  './vendor/lua-fibers/src/?.lua', './vendor/lua-fibers/src/?/init.lua',
  './vendor/lua-bus/src/?.lua', './vendor/lua-bus/src/?/init.lua',
  './vendor/lua-trie/src/?.lua', './vendor/lua-trie/src/?/init.lua',
  package.path,
}, ';')

local config = require 'services.wired.config'
local service = require 'services.wired.service'

local function fail(msg) error(msg, 2) end
local function eq(a, b, msg) if a ~= b then fail((msg or 'values differ') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function ok(v, msg) if v ~= true then fail(msg or 'expected true') end end
local function normalised(raw)
  local intent, err = config.normalise(raw)
  if not intent then fail(err or 'config normalise failed') end
  return intent
end
local function has_violation(snap, kind, fields)
  for _, v in ipairs(snap.violations or {}) do
    if v.kind == kind then
      local match = true
      for k, expected in pairs(fields or {}) do
        if v[k] ~= expected then match = false; break end
      end
      if match then return v end
    end
  end
  return nil
end

local function has_required_vlan(trunk, segment, vlan)
  for _, rec in ipairs((trunk and trunk.required_vlans) or {}) do
    if rec.segment == segment and rec.vlan == vlan then return true end
  end
  return false
end

local net_segments = {
  mgmt = { kind = 'system', protected = true, vlan = { id = 10 } },
  switch_control = { kind = 'system', protected = true, vlan = { id = 11 } },
  fabric = { kind = 'system', protected = true, vlan = { id = 12 } },
  lan = { kind = 'user', vlan = { id = 100 } },
  guest = { kind = 'guest', vlan = { id = 101 } },
}

local wired_intent = normalised({
  schema = config.SCHEMA,
  surfaces = {
    ['switch-uplink-cm5'] = {
      kind = 'switch-port', role = 'internal-trunk', protected = true,
      attachment = {
        mode = 'trunk',
        required_segments = { 'mgmt', 'switch_control', 'fabric' },
        user_segments = 'all-realised-user-segments',
      },
    },
    ['lan-1'] = {
      kind = 'ethernet-port', role = 'access', capabilities = { poe = true },
      attachment = { mode = 'access', segment = 'lan' },
    },
    ['trunk-1'] = {
      kind = 'ethernet-port', role = 'trunk',
      attachment = { mode = 'trunk', segments = { 'lan', 'guest' } },
    },
  },
})

local good = {
  net = { segments = net_segments },
  config_intent = wired_intent,
  assembly = { surfaces = {
    ['switch-uplink-cm5'] = { component = 'switch-main', observed_surface = 'GE8' },
    ['lan-1'] = { component = 'switch-main', observed_surface = 'GE1' },
    ['trunk-1'] = { component = 'switch-main', observed_surface = 'GE2' },
  } },
  observations = {
    ['switch-main'] = {
      status = { state = 'available', available = true },
      surfaces = {
        ['GE8'] = {
          capabilities = { trunk = true, access = false, poe = false },
          attachment = { mode = 'trunk', vlans = { 10, 11, 12, 100, 101 } },
          link = { state = 'up', speed_mbps = 1000 },
        },
        ['GE1'] = {
          capabilities = { access = true, trunk = true, poe = true },
          attachment = { mode = 'access', vlan = 100 },
          link = { state = 'up', speed_mbps = 1000 },
        },
        ['GE2'] = {
          capabilities = { access = true, trunk = true, poe = false },
          attachment = { mode = 'trunk', vlans = { 100, 101 } },
        },
      },
    },
  },
  stats = {},
}
service._test.rebuild_derived(good)
eq(good.state, 'running', 'good fixture should be running')
eq(#(good.violations or {}), 0, 'good fixture violations')
eq(good.surfaces['lan-1'].availability.state, 'available', 'lan-1 availability')
ok(has_required_vlan(good.topology.protected_trunks['switch-uplink-cm5'], 'guest', 101), 'guest expanded into protected trunk')
ok(has_required_vlan(good.topology.protected_trunks['switch-uplink-cm5'], 'lan', 100), 'lan expanded into protected trunk')

local missing_provider = {
  net = { segments = net_segments }, config_intent = wired_intent, assembly = good.assembly, observations = {}, stats = {},
}
service._test.rebuild_derived(missing_provider)
ok(has_violation(missing_provider, 'protected_source_missing', { surface_id = 'switch-uplink-cm5', component = 'switch-main' }) ~= nil, 'protected source missing expected')

local broken = {
  net = { segments = net_segments },
  config_intent = wired_intent,
  assembly = good.assembly,
  observations = {
    ['switch-main'] = {
      status = { state = 'available', available = true },
      surfaces = {
        ['GE8'] = { capabilities = { trunk = true }, attachment = { mode = 'trunk', vlans = { 10, 12, 100 } } },
        ['GE1'] = { capabilities = { access = false, trunk = true, poe = false }, attachment = { mode = 'access', vlan = 100 } },
        ['GE2'] = { capabilities = { access = true, trunk = false, poe = false }, attachment = { mode = 'access', vlan = 100 } },
      },
    },
  },
  stats = {},
}
service._test.rebuild_derived(broken)
ok(has_violation(broken, 'missing_required_segment_carriage', { surface_id = 'switch-uplink-cm5', segment = 'switch_control', vlan = 11 }) ~= nil, 'missing switch_control expected')
ok(has_violation(broken, 'missing_user_segment_carriage', { surface_id = 'switch-uplink-cm5', segment = 'guest', vlan = 101 }) ~= nil, 'missing guest expected')
ok(has_violation(broken, 'observed_surface_does_not_support_access', { surface_id = 'lan-1', observed_surface = 'GE1' }) ~= nil, 'access capability violation expected')
ok(has_violation(broken, 'observed_surface_does_not_support_poe', { surface_id = 'lan-1', observed_surface = 'GE1' }) ~= nil, 'poe capability violation expected')
ok(has_violation(broken, 'observed_surface_does_not_support_trunk', { surface_id = 'trunk-1', observed_surface = 'GE2' }) ~= nil, 'trunk capability violation expected')
eq(broken.state, 'degraded', 'broken fixture state')

print('devicecode wired static provider validation: ok')
LUA

"$SSH" "rm -rf '$REMOTE'; mkdir -p '$REMOTE'"
"$SCP_TO" "$ROOT_DIR/src" "$REMOTE/src"
"$SCP_TO" "$ROOT_DIR/vendor" "$REMOTE/vendor"
"$SCP_TO" "$WORK/run_devicecode_wired_static_provider.lua" "$REMOTE/run_devicecode_wired_static_provider.lua"
"$SSH" "cd '$REMOTE' && lua ./run_devicecode_wired_static_provider.lua"
