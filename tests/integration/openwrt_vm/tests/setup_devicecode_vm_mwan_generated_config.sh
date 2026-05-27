#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(CDPATH= cd -- "$VM_DIR/../../.." && pwd)"
SSH="$VM_DIR/scripts/ssh"
SCP_TO="$VM_DIR/scripts/scp-to"
REMOTE="/tmp/devicecode-vm-real-mwan-config"
mkdir -p "$VM_DIR/work"

ACTIVATE="${DEVICECODE_VM_MWAN_CONFIG_ACTIVATE:-0}"
if [ "$ACTIVATE" = 1 ]; then
	MODE=active
else
	MODE=config
fi
DONE="/tmp/devicecode-vm-real-mwan-config.$MODE.done"
STATUS="/tmp/devicecode-vm-real-mwan-config.$MODE.status"
LOG="/tmp/devicecode-vm-real-mwan-config.$MODE.log"
MARKER="/tmp/devicecode-vm-real-mwan-config.$MODE.ok"
CONFIG_VERSION="devicecode-vm-real-mwan-config-v2-https-sticky"
VERSION="/tmp/devicecode-vm-real-mwan-config.$MODE.version"

echo "[openwrt-vm] applying Devicecode generated MWAN config mode=$MODE"

if [ "${DEVICECODE_VM_MWAN_CONFIG_FORCE:-0}" != 1 ]; then
	if [ "$ACTIVATE" = 1 ]; then
		CHECK_MWAN="mwan3 status >/tmp/devicecode-vm-real-mwan-status.log 2>&1 && grep -q 'balanced:' /tmp/devicecode-vm-real-mwan-status.log && grep -Eq 'S[[:space:]]+https' /tmp/devicecode-vm-real-mwan-status.log"
	else
		CHECK_MWAN="true"
	fi
	if "$SSH" "test -f '$MARKER' && test -f '$VERSION' && [ \"\$(cat '$VERSION' 2>/dev/null)\" = '$CONFIG_VERSION' ] && [ \"\$(uci -q get network.wan.device 2>/dev/null)\" = eth1 ] && [ \"\$(uci -q get network.wanb.device 2>/dev/null)\" = eth2 ] && [ \"\$(uci -q get network.wanc.device 2>/dev/null)\" = eth3 ] && [ \"\$(uci -q get network.wan.metric 2>/dev/null)\" = 11 ] && [ \"\$(uci -q get network.wanb.metric 2>/dev/null)\" = 12 ] && [ \"\$(uci -q get network.wanc.metric 2>/dev/null)\" = 13 ] && $CHECK_MWAN" >/dev/null 2>&1; then
		echo "[openwrt-vm] Devicecode generated MWAN config already installed mode=$MODE"
		exit 0
	fi
fi

cat > "$VM_DIR/work/run_devicecode_vm_real_mwan_apply.lua" <<'LUA'
package.path = table.concat({
  './src/?.lua', './src/?/init.lua',
  './vendor/lua-fibers/src/?.lua', './vendor/lua-fibers/src/?/init.lua',
  './vendor/lua-bus/src/?.lua', './vendor/lua-bus/src/?/init.lua',
  './vendor/lua-trie/src/?.lua', './vendor/lua-trie/src/?/init.lua',
  './fixtures/?.lua',
  package.path,
}, ';')

local fibers = require 'fibers'
local sleep = require 'fibers.sleep'
local exec = require 'fibers.io.exec'
local provider_loader = require 'services.hal.backends.network.provider'
local vm_intent = require 'devicecode_vm_mwan_intent'

local perform = fibers.perform
local function fail(msg) error(msg, 2) end
local function wait_until(pred, timeout_s, label)
  local deadline = fibers.now() + (timeout_s or 1)
  while fibers.now() < deadline do
    if pred() then return true end
    perform(sleep.sleep_op(0.25))
  end
  if pred() then return true end
  fail(label or 'condition was not satisfied before timeout')
end
local function capture(...)
  local cmd = exec.command(...)
  local out, st, code, sig, err = perform(cmd:combined_output_op())
  if st == 'exited' and code == 0 then return out or '' end
  fail('command failed: ' .. table.concat({ ... }, ' ') .. ' ' .. tostring(err or out or st or sig or code))
end
local function ok_cmd(...)
  local cmd = exec.command(...)
  local _out, st, code = perform(cmd:combined_output_op())
  return st == 'exited' and code == 0
end
local function contains(s, needle)
  return type(s) == 'string' and s:find(needle, 1, true) ~= nil
end

fibers.run(function()
  local activate = os.getenv('DEVICECODE_VM_MWAN_CONFIG_ACTIVATE') == '1'
  for _, wan in ipairs(vm_intent.wans) do
    if not ok_cmd('ip', 'link', 'show', wan.device) then
      fail('missing VM WAN interface ' .. wan.device .. '; run the VM with OPENWRT_VM_WAN_IFACES=3')
    end
  end

  local provider_config = { provider = 'openwrt', debounce_s = 0.05 }
  if not activate then
    -- Config-shape tests need real /etc/config files but not disruptive service
    -- reloads.  Keep the activation path exercised while making commands inert.
    provider_config.run_cmd = function(argv)
      print('config-only: skipped activation command ' .. table.concat(argv or {}, ' '))
      return true, nil
    end
  end

  local provider = assert(provider_loader.new(provider_config, {}))
  local intent = vm_intent.intent()
  local valid = perform(provider:validate_op({ intent = intent }))
  if not (valid and valid.ok == true) then fail('validate failed: ' .. tostring(valid and valid.err)) end
  local result = perform(provider:apply_op({ intent = intent, opts = { generation = 24010, apply_id = 'openwrt-vm-real-mwan' } }))
  if not (result and result.ok == true) then fail('apply failed: ' .. tostring(result and result.err)) end

  local mgr = provider._uci_manager
  wait_until(function()
    local st = mgr and mgr.activation_status and mgr:activation_status() or nil
    return st and (st.state == 'done' or st.state == 'idle')
  end, 30, 'activation runner should complete OpenWrt activation work')

  if activate then
    wait_until(function()
      local status = capture('mwan3', 'status')
      return contains(status, 'balanced:') and contains(status, 'wan (') and contains(status, 'wanb (') and contains(status, 'wanc (')
    end, 30, 'mwan3 should expose generated balanced policy')
  end

  provider:terminate('test complete')
end)

print('devicecode VM real MWAN apply: ok')
LUA

"$SSH" "rm -rf '$REMOTE'; mkdir -p '$REMOTE/fixtures'; rm -f '$DONE' '$STATUS' '$LOG' '$MARKER' '$VERSION'"
"$SCP_TO" "$ROOT_DIR/src" "$REMOTE/src"
"$SCP_TO" "$ROOT_DIR/vendor" "$REMOTE/vendor"
"$SCP_TO" "$VM_DIR/fixtures/devicecode_vm_mwan_intent.lua" "$REMOTE/fixtures/devicecode_vm_mwan_intent.lua"
"$SCP_TO" "$VM_DIR/work/run_devicecode_vm_real_mwan_apply.lua" "$REMOTE/run_devicecode_vm_real_mwan_apply.lua"
echo "[openwrt-vm] running Devicecode generated MWAN config apply mode=$MODE"
if ! "$SSH" "cd '$REMOTE' && DEVICECODE_VM_MWAN_CONFIG_ACTIVATE=$ACTIVATE lua ./run_devicecode_vm_real_mwan_apply.lua >'$LOG' 2>&1"; then
	"$SSH" "cat '$LOG' 2>/dev/null || true" >&2 || true
	echo "Devicecode generated MWAN config apply failed mode=$MODE" >&2
	exit 1
fi
"$SSH" "printf '%s\n' '$CONFIG_VERSION' > '$VERSION'; touch '$MARKER'; cat '$LOG'"
