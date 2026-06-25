#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(CDPATH= cd -- "$VM_DIR/../../.." && pwd)"
SSH="$VM_DIR/scripts/ssh"
SCP_TO="$VM_DIR/scripts/scp-to"
REMOTE="/tmp/devicecode-network-observer-event-ingress-test"
WORK="$VM_DIR/work/network-observer-event-ingress-test"

mkdir -p "$WORK"

cat > "$WORK/run_openwrt_network_observer_event_ingress.lua" <<'LUA'
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
local channel = require 'fibers.channel'
local provider_loader = require 'services.hal.backends.network.provider'
local hotplug_client = require 'services.hal.backends.network.providers.openwrt.hotplug_client'

local perform = fibers.perform

local function fail(msg) error(msg, 2) end
local function ok(v, msg) if not v then fail(msg or 'assertion failed') end return v end
local function eq(a, b, msg) if a ~= b then fail((msg or 'values differ') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function note(msg) io.stderr:write('[observer-ingress] ', tostring(msg), '\n') end

local function wait_for_subject(rx, subject, timeout_s)
  local deadline = fibers.now() + (timeout_s or 15.0)
  while fibers.now() < deadline do
    local remaining = deadline - fibers.now()
    if remaining < 0 then remaining = 0 end
    local which, msg = perform(fibers.named_choice({
      event = rx:get_op(),
      timer = sleep.sleep_op(remaining),
    }))
    if which ~= 'event' then break end
    if msg and msg.data and msg.data.subject == subject then return msg.data end
  end
  return nil, 'timed out waiting for ' .. tostring(subject)
end

local function send_with_retry(record, socket_path)
  local last
  for _ = 1, 20 do
    local sent, err = hotplug_client.send(record, { socket_path = socket_path })
    if sent then return true end
    last = err
    perform(sleep.sleep_op(0.05))
  end
  return nil, last
end

local function make_provider(ch, socket_path, opts)
  opts = opts or {}
  local provider, perr = provider_loader.new({
    provider = 'openwrt',
    observer_socket_path = socket_path,
    observer_debounce_s = opts.debounce_s or 0.05,
    enable_live_snapshot = true,
    enable_hotplug_socket = opts.enable_hotplug_socket ~= false,
    enable_ubus_listener = opts.enable_ubus_listener == true,
    initial_observation_snapshot = false,
  }, { cap_emit_ch = ch })
  assert(provider, perr)
  local watch = perform(provider:watch_op({}))
  assert(watch and watch.ok == true, 'watch failed: ' .. tostring(watch and watch.err))
  if socket_path then eq(watch.socket_path, socket_path, 'watch socket path') end
  return provider, watch
end

fibers.run(function(scope)
  local watchdog = assert(scope:child())
  local ok_watchdog, watchdog_err = watchdog:spawn(function()
    perform(sleep.sleep_op(30.0))
    io.stderr:write('openwrt network observer event ingress: timed out\n')
    os.exit(124)
  end)
  assert(ok_watchdog, watchdog_err)

  -- Keep the synthetic hotplug/MWAN socket path isolated from the ubus listener.
  -- When MWAN3 is installed and active, ubus may emit background network events;
  -- those events are valid, but they make this targeted socket-ingress assertion
  -- timing-sensitive.  A separate provider below tests the ubus ingress path.
  note('starting provider watch for direct hotplug ingress')
  local socket_path = '/tmp/devicecode-net-observe-test.sock'
  os.remove(socket_path)
  local ch = channel.new(64)
  local provider = make_provider(ch, socket_path, {
    enable_hotplug_socket = true,
    enable_ubus_listener = false,
  })

  perform(sleep.sleep_op(0.25))
  note('injecting hotplug iface event')

  local sent, serr = provider:ingest_observation({
    source = 'hotplug', kind = 'hotplug', directory = 'iface',
    env = { ACTION = 'ifup', INTERFACE = 'lan', DEVICE = 'br-lan', SUBSYSTEM = 'iface' },
  })
  assert(sent, 'hotplug ingest failed: ' .. tostring(serr))

  local iface_ev = assert(wait_for_subject(ch, 'interface:lan', 15.0))
  note('received interface:lan')
  eq(iface_ev.kind, 'interface_changed', 'hotplug interface event kind')
  ok(type(iface_ev.observed) == 'table', 'hotplug event should include observed snapshot')
  ok(type(iface_ev.observed.live) == 'table', 'hotplug event should include live snapshot')

  note('injecting mwan3 synthetic event')

  sent, serr = provider:ingest_observation({
    source = 'mwan3', kind = 'mwan3', directory = 'mwan3.user',
    env = { ACTION = 'connected', INTERFACE = 'wan', DEVICE = 'eth1' },
  })
  assert(sent, 'mwan3 ingest failed: ' .. tostring(serr))

  local mwan_ev = assert(wait_for_subject(ch, 'mwan:wan', 15.0))
  note('received mwan:wan')
  eq(mwan_ev.kind, 'mwan_member_changed', 'mwan3 event kind')
  ok(type(mwan_ev.observed.multiwan) == 'table', 'mwan3 event should include multiwan snapshot')

  note('terminating direct-ingress provider')
  provider:terminate('direct ingress path complete')
  perform(sleep.sleep_op(0.1))

  note('starting provider watch for ubus')
  local ubus_ch = channel.new(128)
  local ubus_provider = make_provider(ubus_ch, '/tmp/devicecode-net-observe-test-ubus.sock', {
    enable_hotplug_socket = false,
    enable_ubus_listener = true,
    debounce_s = 0.02,
  })

  perform(sleep.sleep_op(0.5))
  note('sending ubus network.interface event')

  local ubus_seen
  for _ = 1, 30 do
    os.execute("ubus send network.interface '{\"action\":\"ifupdate\",\"interface\":\"loopback\"}' >/dev/null 2>&1")
    ubus_seen = wait_for_subject(ubus_ch, 'interface:loopback', 1.0)
    if ubus_seen then break end
  end
  local ubus_ev = assert(ubus_seen, 'timed out waiting for interface:loopback from ubus listener')
  note('received interface:loopback')
  eq(ubus_ev.source, 'ubus', 'ubus listener event source')
  eq(ubus_ev.kind, 'interface_changed', 'ubus interface event kind')

  note('terminating provider')
  ubus_provider:terminate('test complete')
  note('provider terminated')
  watchdog:cancel('test complete')
  perform(watchdog:join_op())
end)

print('openwrt network observer event ingress: ok')
os.exit(0)
LUA

"$SSH" "rm -rf '$REMOTE'; mkdir -p '$REMOTE'"
"$SCP_TO" "$ROOT_DIR/src" "$REMOTE/src"
"$SCP_TO" "$ROOT_DIR/vendor" "$REMOTE/vendor"
"$SCP_TO" "$WORK/run_openwrt_network_observer_event_ingress.lua" "$REMOTE/run_openwrt_network_observer_event_ingress.lua"
"$SSH" "cd '$REMOTE' && lua ./run_openwrt_network_observer_event_ingress.lua"
