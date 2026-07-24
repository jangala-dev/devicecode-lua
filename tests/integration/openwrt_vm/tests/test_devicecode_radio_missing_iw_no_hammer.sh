#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(CDPATH= cd -- "$VM_DIR/../../.." && pwd)"
SSH="$VM_DIR/scripts/ssh"
SCP_TO="$VM_DIR/scripts/scp-to"
REMOTE="/tmp/devicecode-radio-missing-iw-test"
WORK="$VM_DIR/work/radio-missing-iw-test"

mkdir -p "$WORK"

cat > "$WORK/run_devicecode_radio_missing_iw.lua" <<'LUA'
package.path = table.concat({
  './src/?.lua', './src/?/init.lua',
  './vendor/lua-fibers/src/?.lua', './vendor/lua-fibers/src/?/init.lua',
  './vendor/lua-bus/src/?.lua', './vendor/lua-bus/src/?/init.lua',
  './vendor/lua-trie/src/?.lua', './vendor/lua-trie/src/?/init.lua',
  package.path,
}, ';')

local fibers = require 'fibers'
local channel = require 'fibers.channel'
local sleep = require 'fibers.sleep'
local op = require 'fibers.op'
local radio = require 'services.hal.drivers.radio'

local perform = fibers.perform

local function fail(msg) error(msg, 2) end
local function eq(a, b, msg)
  if a ~= b then
    fail((msg or 'values differ') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a))
  end
end

local function wait_for_signal(signal_op, timeout_s, label)
  local signalled = perform(op.boolean_choice(
    signal_op:wrap(function () return true end),
    sleep.sleep_op(timeout_s):wrap(function () return false end)
  ))
  if not signalled then fail(label .. ' did not happen within ' .. tostring(timeout_s) .. 's') end
end

fibers.run(function(scope)
  local errors = {}
  local debug_rows = {}
  local logger = {
    error = function(_, row) errors[#errors + 1] = row end,
    debug = function(_, row) debug_rows[#debug_rows + 1] = row end,
  }

  local driver, err = radio.new('radio0', logger)
  assert(driver, 'failed to create radio driver: ' .. tostring(err))

  local watch_calls = 0
  local terminate_calls = 0
  local backend = driver.backend
  local old_watch_clients_op = backend.watch_clients_op
  local old_terminate = backend.terminate
  local done = channel.new(1)

  function backend:watch_clients_op(...)
    watch_calls = watch_calls + 1
    return old_watch_clients_op(self, ...)
  end

  function backend:terminate(...)
    terminate_calls = terminate_calls + 1
    if old_terminate then return old_terminate(self, ...) end
    return true, nil
  end

  local ok, spawn_err = scope:spawn(function()
    driver:stats_loop()
    perform(done:put_op(true))
  end)
  assert(ok, 'failed to spawn radio stats loop: ' .. tostring(spawn_err))

  wait_for_signal(done:get_op(), 200.0, 'radio stats loop completion')

  eq(watch_calls, 1, 'missing iw should only be watched once after the stream closes')
  eq(terminate_calls, 0, 'startup failure should not register monitor finalizer')
  eq(#errors, 1, 'missing iw should be logged once')
  eq(errors[1].what, 'radio_stats_loop_failed', 'failure log event')
  assert(tostring(errors[1].err or ''):match('iw'), 'failure should mention iw, got: ' .. tostring(errors[1].err))

  print('devicecode radio missing iw no hammer: ok')
  driver.scope:cancel('test complete')
  perform(driver.scope:join_op())
end)
LUA

"$SSH" "rm -rf '$REMOTE'; mkdir -p '$REMOTE'"
"$SSH" "mkdir -p '$REMOTE/src/services' '$REMOTE/src/devicecode/support' '$REMOTE/vendor/lua-fibers'"
"$SCP_TO" "$ROOT_DIR/src/services/hal" "$REMOTE/src/services/hal"
"$SCP_TO" "$ROOT_DIR/src/devicecode/support/queue.lua" "$REMOTE/src/devicecode/support/queue.lua"
"$SCP_TO" "$ROOT_DIR/vendor/lua-fibers/src" "$REMOTE/vendor/lua-fibers/src"
"$SCP_TO" "$WORK/run_devicecode_radio_missing_iw.lua" "$REMOTE/run_devicecode_radio_missing_iw.lua"
"$SSH" "mkdir -p /tmp/devicecode-no-iw-path && lua_bin=\"\$(command -v lua)\" && cd '$REMOTE' && PATH=/tmp/devicecode-no-iw-path \"\$lua_bin\" ./run_devicecode_radio_missing_iw.lua"
