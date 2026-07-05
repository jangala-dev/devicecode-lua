#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(CDPATH= cd -- "$VM_DIR/../../.." && pwd)"
SSH="$VM_DIR/scripts/ssh"
SCP_TO="$VM_DIR/scripts/scp-to"
STAGE_DEVICECODE="$VM_DIR/scripts/ensure-devicecode-staged"
CLEANUP="$VM_DIR/scripts/cleanup-shaping-state"
REMOTE="/tmp/devicecode-segment-shaping-modes"
WORK="$VM_DIR/work/segment-shaping-modes"

mkdir -p "$WORK"
"$CLEANUP" >/dev/null 2>&1 || true
trap 'set +e; "$CLEANUP" >/dev/null 2>&1 || true' EXIT INT TERM

cat > "$WORK/run_segment_shaping_modes.lua" <<'LUA'
package.path = table.concat({
  './src/?.lua', './src/?/init.lua',
  './vendor/lua-fibers/src/?.lua', './vendor/lua-fibers/src/?/init.lua',
  './vendor/lua-bus/src/?.lua', './vendor/lua-bus/src/?/init.lua',
  './vendor/lua-trie/src/?.lua', './vendor/lua-trie/src/?/init.lua',
  package.path,
}, ';')

local fibers = require 'fibers'
local exec = require 'fibers.io.exec'
local tc_u32 = require 'services.hal.backends.network.providers.openwrt.tc_u32_shaper'
local unpack = table.unpack or unpack
local perform = fibers.perform

local function run(argv)
  local cmd = exec.command(unpack(argv))
  local out, st, code = perform(cmd:combined_output_op())
  if st == 'exited' and code == 0 then return true, out or '', nil, code end
  return nil, out or '', out or 'command failed', code
end

local function apply_link(iface, mode, aggregate)
  local egress = {
    enabled = true,
    mode = mode,
    match = 'dst',
    host_rate = '2mbit', host_ceil = '8mbit', host_burst = '100k', host_cburst = '100k',
    fq_codel = { flows = 128, limit = 1024, memory_limit = '1Mb' },
    hosts = { ['172.29.32.36'] = { rate = '1mbit', ceil = '3mbit', burst = '50k', cburst = '50k' } },
  }
  if aggregate then
    egress.segment_aggregate = true
    egress.pool_rate = '8mbit'
    egress.pool_ceil = '8mbit'
  end
  local result = tc_u32.apply({
    links = {
      test = {
        iface = iface,
        subnet = '172.29.32.1/24',
        egress = egress,
        ingress = { enabled = false },
      },
    },
  }, { run_cmd = run })
  assert(result and result.ok == true, tostring(result and result.err))
end

fibers.run(function()
  apply_link('dcs-bflat', 'budgeted_peak', false)
  apply_link('dcs-bagg', 'budgeted_peak', true)
  apply_link('dcshape-borrow', 'borrow_to_ceil', true)
end)

print('openwrt segment shaping modes apply: ok')
LUA

"$SSH" "rm -rf '$REMOTE'; mkdir -p '$REMOTE'; ip link add dcs-bflat type veth peer name dcs-bflatp; ip link set dcs-bflat up; ip link set dcs-bflatp up; ip link add dcs-bagg type veth peer name dcs-baggp; ip link set dcs-bagg up; ip link set dcs-baggp up; ip link add dcshape-borrow type veth peer name dcshape-borrowp; ip link set dcshape-borrow up; ip link set dcshape-borrowp up"
CODE_REMOTE="$($STAGE_DEVICECODE)"
"$SCP_TO" "$WORK/run_segment_shaping_modes.lua" "$REMOTE/run.lua"
"$SSH" "cd '$CODE_REMOTE' && lua '$REMOTE/run.lua'"

"$SSH" 'set -eu
fail() { echo "segment shaping modes test: $*" >&2; exit 1; }

# budgeted_peak without aggregate: root -> host budget -> host peak -> fq_codel
tc class show dev dcs-bflat | grep -q "class htb 1:1036" || fail "flat budgeted_peak budget class should be 1:1036"
tc qdisc show dev dcs-bflat | grep -q "parent 1:1036" || fail "flat budgeted_peak should attach a peak HTB qdisc to 1:1036"
tc class show dev dcs-bflat | grep -q "class htb 1036:1" || fail "flat budgeted_peak peak class should be 1036:1"
tc qdisc show dev dcs-bflat | grep -q "parent 1036:1" || fail "flat budgeted_peak fq_codel should attach to 1036:1"
if tc class show dev dcs-bflat | grep -q "class htb 1:20"; then
  fail "flat budgeted_peak should not create a segment aggregate class"
fi
if tc class show dev dcs-bflat | grep -q "class htb 20:1036"; then
  fail "flat budgeted_peak should not create aggregate budget class 20:1036"
fi

# budgeted_peak with aggregate: root -> segment aggregate -> host budget -> host peak -> fq_codel
tc class show dev dcs-bagg | grep -q "class htb 1:20" || fail "aggregate budgeted_peak should create segment aggregate 1:20"
tc qdisc show dev dcs-bagg | grep -Eq "qdisc htb 20: .*parent 1:20" || fail "aggregate budgeted_peak should attach inner HTB to 1:20"
tc class show dev dcs-bagg | grep -q "class htb 20:1036" || fail "aggregate budgeted_peak budget class should be 20:1036"
tc qdisc show dev dcs-bagg | grep -q "parent 20:1036" || fail "aggregate budgeted_peak should attach a peak HTB qdisc to 20:1036"
tc class show dev dcs-bagg | grep -q "class htb 1036:1" || fail "aggregate budgeted_peak peak class should be 1036:1"
tc qdisc show dev dcs-bagg | grep -q "parent 1036:1" || fail "aggregate budgeted_peak fq_codel should attach to 1036:1"

# borrow_to_ceil keeps the existing inner-pool host leaf semantics.
tc class show dev dcshape-borrow | grep -q "class htb 20:1036" || fail "borrow_to_ceil host class should be 20:1036"
if tc class show dev dcshape-borrow | grep -q "class htb 1036:1"; then
  fail "borrow_to_ceil should not create a budgeted peak class 1036:1"
fi
tc qdisc show dev dcshape-borrow | grep -q "parent 20:1036" || fail "borrow_to_ceil fq_codel should attach to 20:1036"

printf "%s\n" "openwrt segment shaping modes topology: ok"
'

