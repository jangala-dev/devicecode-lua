#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(CDPATH= cd -- "$VM_DIR/../../.." && pwd)"
SSH="$VM_DIR/scripts/ssh"
SCP_TO="$VM_DIR/scripts/scp-to"
REMOTE="/tmp/devicecode-network-provider-live-snapshot-test"
WORK="$VM_DIR/work/network-provider-live-snapshot-test"

mkdir -p "$WORK"

cat > "$WORK/run_openwrt_network_provider_live_snapshot.lua" <<'LUA'
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
local provider_loader = require 'services.hal.backends.network.provider'

local perform = fibers.perform

local function fail(msg) error(msg, 2) end
local function ok(v, msg) if not v then fail(msg or 'assertion failed') end return v end
local function eq(a, b, msg) if a ~= b then fail((msg or 'values differ') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end

fibers.run(function(_scope)
  local provider, perr = provider_loader.new({
    provider = 'openwrt',
    enable_live_snapshot = true,
    enable_hotplug_socket = false,
    enable_ubus_listener = false,
  }, {})
  assert(provider, perr)

  local snapshot = perform(provider:snapshot_op({ live = true, interfaces = { 'loopback', 'lan' } }))
  assert(snapshot and snapshot.ok == true, 'snapshot failed: ' .. tostring(snapshot and snapshot.err))
  eq(snapshot.backend, 'openwrt', 'snapshot backend')

  local observed = ok(snapshot.observed, 'observed snapshot expected')
  eq(observed.schema, 'devicecode.net.observed/1', 'observed schema')
  ok(type(observed.live) == 'table', 'live snapshot expected')
  ok(type(observed.live.interfaces) == 'table', 'live interfaces expected')
  ok(type(observed.live.routes) == 'table', 'live routes expected')
  ok(type(observed.live.devices) == 'table', 'live devices expected')
  ok(type(observed.multiwan) == 'table', 'multiwan observation expected')

  local have_iface = observed.live.interfaces.loopback ~= nil or observed.live.interfaces.lan ~= nil
  ok(have_iface, 'expected live status for loopback or lan')
  if observed.live.interfaces.loopback then
    eq(observed.live.interfaces.loopback.id, 'loopback', 'loopback id')
    ok(observed.live.interfaces.loopback.raw ~= nil, 'loopback raw status expected')
  end

  if observed.multiwan.available then
    ok(type(observed.multiwan.interfaces) == 'table', 'mwan interfaces expected')
    ok(type(observed.multiwan.policies) == 'table', 'mwan policies expected')
  else
    ok(type(observed.multiwan.err) == 'string', 'mwan unavailable should carry an error')
  end

  provider:terminate('test complete')
end)

print('openwrt network provider live snapshot: ok')
LUA

"$SSH" "rm -rf '$REMOTE'; mkdir -p '$REMOTE'"
"$SCP_TO" "$ROOT_DIR/src" "$REMOTE/src"
"$SCP_TO" "$ROOT_DIR/vendor" "$REMOTE/vendor"
"$SCP_TO" "$WORK/run_openwrt_network_provider_live_snapshot.lua" "$REMOTE/run_openwrt_network_provider_live_snapshot.lua"
"$SSH" "cd '$REMOTE' && lua ./run_openwrt_network_provider_live_snapshot.lua"
