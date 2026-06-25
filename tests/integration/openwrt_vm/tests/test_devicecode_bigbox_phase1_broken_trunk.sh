#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(CDPATH= cd -- "$VM_DIR/../../.." && pwd)"
SSH="$VM_DIR/scripts/ssh"
SCP_TO="$VM_DIR/scripts/scp-to"
REMOTE="/tmp/devicecode-bigbox-phase1-broken-trunk-test"
WORK="$VM_DIR/work/bigbox-phase1-broken-trunk-test"

mkdir -p "$WORK"
cat > "$WORK/run_devicecode_bigbox_phase1_broken_trunk.lua" <<'LUA'
package.path = table.concat({
  './src/?.lua', './src/?/init.lua',
  './vendor/lua-fibers/src/?.lua', './vendor/lua-fibers/src/?/init.lua',
  './vendor/lua-bus/src/?.lua', './vendor/lua-bus/src/?/init.lua',
  './vendor/lua-trie/src/?.lua', './vendor/lua-trie/src/?/init.lua',
  package.path,
}, ';')

local fibers = require 'fibers'
local bus = require 'bus'
local wired_config = require 'services.wired.config'
local wired_service = require 'services.wired.service'
local wired_publisher = require 'services.wired.publisher'
local wired_topics = require 'services.wired.topics'

local function fail(msg) error(msg, 2) end
local function eq(a, b, msg) if a ~= b then fail((msg or 'values differ') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function ok(v, msg) if v ~= true then fail(msg or 'expected true') end end
local function retained_payload(conn, topic)
  local v = conn:retained_view({ '#' })
  local msg = v:get(topic)
  v:close()
  if not msg then fail('missing retained topic ' .. table.concat(topic, '/')) end
  return msg.payload
end
local function find_violation(list, kind, fields)
  for _, v in ipairs(list or {}) do
    if v.kind == kind then
      local match = true
      for k, expected in pairs(fields or {}) do if v[k] ~= expected then match = false; break end end
      if match then return v end
    end
  end
  return nil
end

local segments = {
  mgmt = { kind = 'system', protected = true, vlan = { id = 10 } },
  switch_control = { kind = 'system', protected = true, vlan = { id = 11 } },
  fabric = { kind = 'system', protected = true, vlan = { id = 12 } },
  lan = { kind = 'user', vlan = { id = 100 } },
  guest = { kind = 'guest', vlan = { id = 101 } },
}
local intent, err = wired_config.normalise({
  schema = wired_config.SCHEMA,
  surfaces = {
    ['switch-uplink-cm5'] = {
      kind = 'switch-port', role = 'internal-trunk', protected = true,
      attachment = { mode = 'trunk', required_segments = { 'mgmt', 'switch_control', 'fabric' }, user_segments = 'all-realised-user-segments' },
    },
    ['lan-1'] = {
      kind = 'ethernet-port', role = 'access',
      attachment = { mode = 'access', segment = 'lan' },
    },
  },
})
if not intent then fail(err) end

fibers.run(function()
  local b = bus.new()
  local conn = b:connect({ origin_base = { kind = 'vm-test' } })
  local snap = {
    net = { segments = segments },
    config_intent = intent,
    assembly = { surfaces = {
      ['switch-uplink-cm5'] = { component = 'switch-main', observed_surface = 'GE8' },
      ['lan-1'] = { component = 'switch-main', observed_surface = 'GE1' },
    } },
    observations = {
      ['switch-main'] = {
        status = { state = 'available', available = true, mode = 'read_only' },
        surfaces = {
          ['GE8'] = {
            observed_surface = 'GE8', kind = 'switch-port', capabilities = { trunk = true, access = false },
            link = { state = 'up', speed_mbps = 1000 },
            -- Missing switch_control VLAN 11 and guest VLAN 101.
            attachment = { mode = 'trunk', vlans = { 10, 12, 100 } },
          },
          ['GE1'] = {
            observed_surface = 'GE1', kind = 'ethernet-port', capabilities = { access = true, trunk = true },
            attachment = { mode = 'access', vlan = 100 },
          },
        },
      },
    },
    stats = {},
  }
  wired_service._test.rebuild_derived(snap)
  local ok_pub, perr = wired_publisher.publish_all_now(conn, snap, wired_publisher.new_state())
  if ok_pub ~= true then fail(perr or 'wired publish failed') end

  eq(snap.state, 'degraded', 'snap state')
  ok(find_violation(snap.violations, 'missing_required_segment_carriage', { surface_id = 'switch-uplink-cm5', segment = 'switch_control', vlan = 11 }) ~= nil, 'missing switch_control violation')
  ok(find_violation(snap.violations, 'missing_user_segment_carriage', { surface_id = 'switch-uplink-cm5', segment = 'guest', vlan = 101 }) ~= nil, 'missing guest violation')

  local published = retained_payload(conn, wired_topics.violations())
  ok(find_violation(published, 'missing_required_segment_carriage', { surface_id = 'switch-uplink-cm5', segment = 'switch_control', vlan = 11 }) ~= nil, 'published missing switch_control violation')
  local uplink = retained_payload(conn, wired_topics.surface('switch-uplink-cm5'))
  eq(uplink.availability.state, 'available', 'uplink link still observed available')
end)

print('devicecode Big Box phase 1 broken trunk: ok')
LUA

"$SSH" "rm -rf '$REMOTE'; mkdir -p '$REMOTE'"
"$SCP_TO" "$ROOT_DIR/src" "$REMOTE/src"
"$SCP_TO" "$ROOT_DIR/vendor" "$REMOTE/vendor"
"$SCP_TO" "$WORK/run_devicecode_bigbox_phase1_broken_trunk.lua" "$REMOTE/run_devicecode_bigbox_phase1_broken_trunk.lua"
"$SSH" "cd '$REMOTE' && lua ./run_devicecode_bigbox_phase1_broken_trunk.lua"
