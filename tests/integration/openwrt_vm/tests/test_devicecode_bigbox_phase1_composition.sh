#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(CDPATH= cd -- "$VM_DIR/../../.." && pwd)"
SSH="$VM_DIR/scripts/ssh"
SCP_TO="$VM_DIR/scripts/scp-to"
REMOTE="/tmp/devicecode-bigbox-phase1-composition-test"
WORK="$VM_DIR/work/bigbox-phase1-composition-test"

mkdir -p "$WORK"
cat > "$WORK/run_devicecode_bigbox_phase1_composition.lua" <<'LUA'
package.path = table.concat({
  './src/?.lua', './src/?/init.lua',
  './vendor/lua-fibers/src/?.lua', './vendor/lua-fibers/src/?/init.lua',
  './vendor/lua-bus/src/?.lua', './vendor/lua-bus/src/?/init.lua',
  './vendor/lua-trie/src/?.lua', './vendor/lua-trie/src/?/init.lua',
  package.path,
}, ';')

local fibers = require 'fibers'
local bus = require 'bus'
local device_config = require 'services.device.config'
local device_model = require 'services.device.model'
local device_publisher = require 'services.device.publisher'
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

local function build_device_assembly(conn)
  local catalogue, err = device_config.to_catalogue({
    schema = device_config.SCHEMA,
    assembly = {
      product = 'big-box',
      components = {
        ['switch-main'] = { kind = 'switch', role = 'wired-fabric' },
        ['cm5-local-wired'] = { kind = 'direct-nic', role = 'controller-wired-port' },
      },
      links = {
        ['cm5-switch'] = {
          kind = 'wired', role = 'controller-switch-uplink', internal = true,
          a = { component = 'cm5-local-wired', observed_surface = 'eth0' },
          b = { component = 'switch-main', observed_surface = 'GE8' },
        },
      },
      surfaces = {
        ['cm5-eth0'] = { component = 'cm5-local-wired', observed_surface = 'eth0', exposure = 'internal' },
        ['switch-uplink-cm5'] = { component = 'switch-main', observed_surface = 'GE8', exposure = 'internal' },
        ['lan-1'] = { component = 'switch-main', observed_surface = 'GE1', exposure = 'external' },
        ['lan-2'] = { component = 'switch-main', observed_surface = 'GE2', exposure = 'external' },
      },
    },
    components = {
      ['switch-main'] = {
        kind = 'switch', module = 'switch', class = 'member', role = 'wired-fabric', member = 'switch-main',
        facts = { wired_observation_status = { 'raw', 'host', 'wired', 'provider', 'switch-main', 'status' } },
      },
    },
  })
  if not catalogue then fail(err) end

  local model = device_model.new()
  ok((select(1, model:apply_catalogue(1, catalogue))) ~= nil, 'catalogue apply')
  local snap = model:snapshot()
  local ok_pub, perr = device_publisher.publish_summary_now(conn, snap, { emit_event = false })
  if ok_pub ~= true then fail(perr or 'device assembly publish failed') end
end

local function retain_raw_wired_facts(conn)
  conn:retain({ 'raw', 'host', 'wired', 'provider', 'cm5-local-wired', 'status' }, { state = 'available', available = true })
  conn:retain({ 'raw', 'host', 'wired', 'provider', 'cm5-local-wired', 'state', 'surfaces' }, { surfaces = {
    eth0 = { capabilities = { trunk = true }, link = { state = 'up', speed_mbps = 1000 }, attachment = { mode = 'trunk', vlans = { 10, 11, 12, 100, 101 } } },
  } })
  conn:retain({ 'raw', 'host', 'wired', 'provider', 'cm5-local-wired', 'state', 'topology' }, {})
  conn:retain({ 'raw', 'host', 'wired', 'provider', 'switch-main', 'status' }, { state = 'available', available = true, mode = 'read_only', driver = 'rtl8380m_http' })
  conn:retain({ 'raw', 'host', 'wired', 'provider', 'switch-main', 'state', 'surfaces' }, { surfaces = {
    ['GE8'] = {
      provider_surface_id = 'GE8', kind = 'switch-port',
      capabilities = { trunk = true, access = false, poe = false },
      link = { state = 'up', speed_mbps = 1000 },
      attachment = { mode = 'trunk', vlans = { 10, 11, 12, 100, 101 } },
    },
    ['GE1'] = {
      provider_surface_id = 'GE1', kind = 'ethernet-port',
      capabilities = { access = true, trunk = true, poe = true },
      link = { state = 'up', speed_mbps = 1000 },
      attachment = { mode = 'access', vlan = 100 },
    },
    ['GE2'] = {
      provider_surface_id = 'GE2', kind = 'ethernet-port',
      capabilities = { access = true, trunk = true, poe = true },
      link = { state = 'down' },
      attachment = { mode = 'access', vlan = 101 },
    },
  } })
  conn:retain({ 'raw', 'host', 'wired', 'provider', 'switch-main', 'state', 'topology' }, { trunks = { ['GE8'] = { vlans = { 10, 11, 12, 100, 101 } } } })
end

local function raw_provider(conn, provider_id)
  local status = retained_payload(conn, { 'raw', 'host', 'wired', 'provider', provider_id, 'status' })
  local surfaces_payload = retained_payload(conn, { 'raw', 'host', 'wired', 'provider', provider_id, 'state', 'surfaces' })
  local topology_payload = retained_payload(conn, { 'raw', 'host', 'wired', 'provider', provider_id, 'state', 'topology' })
  return { status = status, surfaces = surfaces_payload.surfaces or surfaces_payload, topology = topology_payload }
end

local function compose_wired(conn)
  local assembly = retained_payload(conn, { 'state', 'device', 'assembly' })

  local intent, err = wired_config.normalise({
    schema = wired_config.SCHEMA,
    surfaces = {
      ['cm5-eth0'] = {
        kind = 'direct-nic', role = 'internal-trunk', protected = true,
        attachment = { mode = 'trunk', required_segments = { 'mgmt', 'switch_control', 'fabric' }, user_segments = 'all-realised-user-segments' },
      },
      ['switch-uplink-cm5'] = {
        kind = 'switch-port', role = 'internal-trunk', protected = true,
        attachment = { mode = 'trunk', required_segments = { 'mgmt', 'switch_control', 'fabric' }, user_segments = 'all-realised-user-segments' },
      },
      ['lan-1'] = {
        kind = 'ethernet-port', role = 'access', label = 'LAN 1', capabilities = { poe = true },
        attachment = { mode = 'access', segment = 'lan' },
      },
      ['lan-2'] = {
        kind = 'ethernet-port', role = 'access', label = 'LAN 2', capabilities = { poe = true },
        attachment = { mode = 'access', segment = 'guest' },
      },
    },
  })
  if not intent then fail(err) end

  local snap = {
    assembly = assembly,
    net = { segments = {
      mgmt = { kind = 'system', protected = true, vlan = { id = 10 } },
      switch_control = { kind = 'system', protected = true, vlan = { id = 11 } },
      fabric = { kind = 'system', protected = true, vlan = { id = 12 } },
      lan = { kind = 'user', vlan = { id = 100 } },
      guest = { kind = 'guest', vlan = { id = 101 } },
    } },
    config_intent = intent,
    providers = {
      ['cm5-local-wired'] = raw_provider(conn, 'cm5-local-wired'),
      ['switch-main'] = raw_provider(conn, 'switch-main'),
    },
    stats = {},
  }
  wired_service._test.rebuild_derived(snap)
  local ok_pub, perr = wired_publisher.publish_all_now(conn, snap, wired_publisher.new_state())
  if ok_pub ~= true then fail(perr or 'wired publish failed') end
  return snap
end

fibers.run(function()
  local b = bus.new()
  local conn = b:connect({ origin_base = { kind = 'vm-test' } })
  conn:retain({ 'state', 'net', 'segments' }, { rev = 1, segments = {
    mgmt = { kind = 'system', protected = true, vlan = { id = 10 } },
    switch_control = { kind = 'system', protected = true, vlan = { id = 11 } },
    fabric = { kind = 'system', protected = true, vlan = { id = 12 } },
    lan = { kind = 'user', vlan = { id = 100 } },
    guest = { kind = 'guest', vlan = { id = 101 } },
  } })

  build_device_assembly(conn)
  retain_raw_wired_facts(conn)
  local assembly = retained_payload(conn, { 'state', 'device', 'assembly' })
  eq(assembly.surfaces['lan-1'].observed_surface, 'GE1', 'device assembly maps lan-1')

  local snap = compose_wired(conn)
  eq(snap.state, 'running', 'wired composed state')
  eq(#(snap.violations or {}), 0, 'wired violations')

  local lan1 = retained_payload(conn, wired_topics.surface('lan-1'))
  eq(lan1.surface_id, 'lan-1', 'lan-1 surface id')
  eq(lan1.attachment.segment, 'lan', 'lan-1 segment')
  eq(lan1.availability.state, 'available', 'lan-1 available')

  local uplink = retained_payload(conn, wired_topics.surface('switch-uplink-cm5'))
  eq(uplink.availability.state, 'available', 'switch uplink available')
  local violations = retained_payload(conn, wired_topics.violations())
  eq(#(violations.violations or {}), 0, 'published violations empty')
end)

print('devicecode Big Box phase 1 composition: ok')
LUA

"$SSH" "rm -rf '$REMOTE'; mkdir -p '$REMOTE'"
"$SCP_TO" "$ROOT_DIR/src" "$REMOTE/src"
"$SCP_TO" "$ROOT_DIR/vendor" "$REMOTE/vendor"
"$SCP_TO" "$WORK/run_devicecode_bigbox_phase1_composition.lua" "$REMOTE/run_devicecode_bigbox_phase1_composition.lua"
"$SSH" "cd '$REMOTE' && lua ./run_devicecode_bigbox_phase1_composition.lua"
