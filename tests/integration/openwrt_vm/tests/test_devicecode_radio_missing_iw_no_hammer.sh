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
local provider = require 'services.hal.backends.radio.provider'

local function fail(msg) error(msg, 2) end
local function eq(a, b, msg)
  if a ~= b then
    fail((msg or 'values differ') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a))
  end
end

fibers.run(function()
  local backend, err = provider.new('radio0')

  eq(backend, nil, 'radio backend should not be selected without iw in PATH')
  assert(tostring(err or ''):match('no supported radio backend'), 'unexpected provider error: ' .. tostring(err))
  eq(package.loaded['services.hal.backends.radio.providers.openwrt.impl'], nil,
    'unsupported radio provider should not load the OpenWrt implementation')
  print('devicecode radio missing iw no hammer: ok')
end)
LUA

"$SSH" "rm -rf '$REMOTE'; mkdir -p '$REMOTE'"
"$SSH" "mkdir -p '$REMOTE/src/services/hal/backends/radio/providers/openwrt' '$REMOTE/vendor/lua-fibers'"
"$SCP_TO" "$ROOT_DIR/src/services/hal/backends/radio/provider.lua" "$REMOTE/src/services/hal/backends/radio/provider.lua"
"$SCP_TO" "$ROOT_DIR/src/services/hal/backends/radio/contract.lua" "$REMOTE/src/services/hal/backends/radio/contract.lua"
"$SCP_TO" "$ROOT_DIR/src/services/hal/backends/radio/providers/openwrt/init.lua" "$REMOTE/src/services/hal/backends/radio/providers/openwrt/init.lua"
"$SCP_TO" "$ROOT_DIR/vendor/lua-fibers/src" "$REMOTE/vendor/lua-fibers/src"
"$SCP_TO" "$WORK/run_devicecode_radio_missing_iw.lua" "$REMOTE/run_devicecode_radio_missing_iw.lua"
"$SSH" "mkdir -p /tmp/devicecode-no-iw-path && lua_bin=\"\$(command -v lua)\" && cd '$REMOTE' && PATH=/tmp/devicecode-no-iw-path \"\$lua_bin\" ./run_devicecode_radio_missing_iw.lua"
