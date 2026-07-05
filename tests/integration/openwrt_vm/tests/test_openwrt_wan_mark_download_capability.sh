#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(CDPATH= cd -- "$VM_DIR/../../.." && pwd)"
SSH="$VM_DIR/scripts/ssh"
SCP_TO="$VM_DIR/scripts/scp-to"
STAGE_DEVICECODE="$VM_DIR/scripts/ensure-devicecode-staged"
CLEANUP="$VM_DIR/scripts/cleanup-shaping-state"
REMOTE="/tmp/devicecode-wan-mark-download-capability"
WORK="$VM_DIR/work/wan-mark-download-capability"

mkdir -p "$WORK"
"$CLEANUP" >/dev/null 2>&1 || true
trap 'set +e; "$CLEANUP" >/dev/null 2>&1 || true' EXIT INT TERM

cat > "$WORK/run_wan_mark_download_capability.lua" <<'LUA'
package.path = table.concat({
  './src/?.lua', './src/?/init.lua',
  './vendor/lua-fibers/src/?.lua', './vendor/lua-fibers/src/?/init.lua',
  './vendor/lua-bus/src/?.lua', './vendor/lua-bus/src/?/init.lua',
  './vendor/lua-trie/src/?.lua', './vendor/lua-trie/src/?/init.lua',
  package.path,
}, ';')

local fibers = require 'fibers'
local exec = require 'fibers.io.exec'
local tc_mark = require 'services.hal.backends.network.providers.openwrt.tc_mark_shaper'
local unpack = table.unpack or unpack
local perform = fibers.perform

local function run(argv)
  local cmd = exec.command(unpack(argv))
  local out, st, code = perform(cmd:combined_output_op())
  if st == 'exited' and code == 0 then return true, out or '', nil, code end
  return nil, out or '', out or 'command failed', code
end

local result
fibers.run(function()
  result = tc_mark.apply({
    marks = { mask = '0x00f00000', control = '0x00100000', client = '0x00200000' },
    links = {
      cap = {
        kind = 'wan_mark', iface = 'dcwan-cap',
        egress = { enabled = false },
        ingress = {
          enabled = true, ifb = 'ifb_dcwan_cap',
          root = { rate = '1gbit', ceil = '1gbit' },
          control = { rate = '1gbit', ceil = '1gbit' },
          client = { rate = '8mbit', ceil = '8mbit' },
          fq_codel = { flows = 128, limit = 1024, memory_limit = '1Mb' },
        },
      },
    },
  }, { run_cmd = run })
end)

if result and result.ok == true then
  print('WAN_DOWNLOAD_CAPABILITY=supported')
else
  print('WAN_DOWNLOAD_CAPABILITY=unsupported')
  print('WAN_DOWNLOAD_ERROR=' .. tostring(result and result.err or 'unknown'))
end
LUA

"$SSH" 'set -eu
modprobe ifb 2>/dev/null || true
modprobe sch_htb 2>/dev/null || true
modprobe sch_ingress 2>/dev/null || true
modprobe sch_fq_codel 2>/dev/null || true
modprobe cls_u32 2>/dev/null || true
modprobe cls_fw 2>/dev/null || true
modprobe act_mirred 2>/dev/null || true
modprobe act_ctinfo 2>/dev/null || true
ip link del dcwan-cap 2>/dev/null || true
ip link del ifb_dcwan_cap 2>/dev/null || true
ip link add dcwan-cap type veth peer name dcwan-capp
ip link set dcwan-cap up
ip link set dcwan-capp up
'

"$SSH" "rm -rf '$REMOTE'; mkdir -p '$REMOTE'"
CODE_REMOTE="$($STAGE_DEVICECODE)"
"$SCP_TO" "$WORK/run_wan_mark_download_capability.lua" "$REMOTE/run.lua"
out="$($SSH "cd '$CODE_REMOTE' && lua '$REMOTE/run.lua'")"
printf '%s\n' "$out"

case "$out" in
  *WAN_DOWNLOAD_CAPABILITY=supported*)
    "$SSH" 'set -eu
      fail() { echo "wan mark download capability test: $*" >&2; exit 1; }
      tc qdisc show dev dcwan-cap | grep -q "qdisc ingress ffff:" || fail "supported path should install ingress qdisc"
      tc filter show dev dcwan-cap parent ffff: | grep -q "ctinfo" || fail "supported path should restore connmark with ctinfo"
      tc qdisc show dev ifb_dcwan_cap | grep -q "qdisc htb 1:" || fail "supported path should install IFB root HTB"
      tc class show dev ifb_dcwan_cap | grep -q "class htb 1:10" || fail "supported path should install control class"
      tc class show dev ifb_dcwan_cap | grep -q "class htb 1:20" || fail "supported path should install client class"
      printf "%s\n" "openwrt wan mark download capability: supported"
    '
    ;;
  *WAN_DOWNLOAD_CAPABILITY=unsupported*)
    "$SSH" 'set -eu
      fail() { echo "wan mark download capability test: $*" >&2; exit 1; }
      if tc qdisc show dev ifb_dcwan_cap 2>/dev/null | grep -q "qdisc htb 1:"; then
        fail "unsupported path should not install misleading IFB shaping root"
      fi
      printf "%s\n" "openwrt wan mark download capability: unsupported safely reported"
    '
    ;;
  *)
    echo "wan mark download capability test: could not determine capability" >&2
    exit 1
    ;;
esac

