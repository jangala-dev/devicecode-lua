#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(CDPATH= cd -- "$VM_DIR/../../.." && pwd)"
SSH="$VM_DIR/scripts/ssh"
SCP_TO="$VM_DIR/scripts/scp-to"
STAGE_DEVICECODE="$VM_DIR/scripts/ensure-devicecode-staged"
CLEANUP="$VM_DIR/scripts/cleanup-shaping-state"
REMOTE="/tmp/devicecode-shaping-idempotent-apply"
WORK="$VM_DIR/work/shaping-idempotent-apply"

mkdir -p "$WORK"
"$CLEANUP" >/dev/null 2>&1 || true
trap 'set +e; "$CLEANUP" >/dev/null 2>&1 || true' EXIT INT TERM

cat > "$WORK/run_shaping_idempotent_apply.lua" <<'LUA'
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

local function link(iface, host_rate, ifb_name)
  return {
    iface = iface,
    subnet = '172.30.32.1/24',
    egress = {
      enabled = true, mode = 'budgeted_peak', match = 'dst',
      pool_rate = '8mbit', pool_ceil = '8mbit',
      host_rate = host_rate or '2mbit', host_ceil = '6mbit', host_burst = '100k', host_cburst = '100k',
      fq_codel = { flows = 128, limit = 1024, memory_limit = '1Mb' },
      hosts = { ['172.30.32.36'] = { rate = host_rate or '2mbit', ceil = '6mbit', burst = '100k', cburst = '100k' } },
    },
    ingress = {
      enabled = true, mode = 'budgeted_peak', match = 'src', ifb = ifb_name or 'ifb_dcs_idem',
      pool_rate = '8mbit', pool_ceil = '8mbit',
      host_rate = host_rate or '2mbit', host_ceil = '6mbit', host_burst = '100k', host_cburst = '100k',
      fq_codel = { flows = 128, limit = 1024, memory_limit = '1Mb' },
      hosts = { ['172.30.32.36'] = { rate = host_rate or '2mbit', ceil = '6mbit', burst = '100k', cburst = '100k' } },
    },
  }
end

local function apply(iface, host_rate, ifb_name)
  local result = tc_u32.apply({ links = { test = link(iface, host_rate, ifb_name) } }, { run_cmd = run })
  assert(result and result.ok == true, tostring(result and result.err))
end

fibers.run(function()
  -- Exercise explicit cleanup of a former target so stale old attachments do not
  -- remain after a target migration.
  apply('dcshape-old', '2mbit', 'ifb_dcshape_old')
  local ok, err = tc_u32.clear('dcshape-old', { ifb = 'ifb_dcshape_old', delete_ifb = true, run_cmd = run })
  assert(ok == true, tostring(err))

  -- Repeated applies on the active target should be safe and should preserve the
  -- live data plane.  The third apply changes a host class rate so the class
  -- reconciliation path is also exercised.
  apply('dcshape-idem', '2mbit')
  apply('dcshape-idem', '2mbit')
  apply('dcshape-idem', '3mbit')
end)

print('openwrt shaping idempotent apply: ok')
LUA

"$SSH" "rm -rf '$REMOTE'; mkdir -p '$REMOTE'; ip netns del dcshape-idem-peer 2>/dev/null || true; ip link add dcshape-idem type veth peer name dcshape-idemp; ip link set dcshape-idem up; ip addr add 172.30.32.1/24 dev dcshape-idem; ip netns add dcshape-idem-peer; ip link set dcshape-idemp netns dcshape-idem-peer; ip netns exec dcshape-idem-peer ip link set lo up; ip netns exec dcshape-idem-peer ip link set dcshape-idemp up; ip netns exec dcshape-idem-peer ip addr add 172.30.32.36/24 dev dcshape-idemp; ip netns exec dcshape-idem-peer ip route replace default via 172.30.32.1 dev dcshape-idemp; ip link add dcshape-old type veth peer name dcshape-oldp; ip link set dcshape-old up; ip link set dcshape-oldp up"
CODE_REMOTE="$($STAGE_DEVICECODE)"
"$SCP_TO" "$WORK/run_shaping_idempotent_apply.lua" "$REMOTE/run.lua"
"$SSH" "cd '$CODE_REMOTE' && lua '$REMOTE/run.lua'"

"$SSH" 'set -eu
fail() { echo "shaping idempotent apply test: $*" >&2; exit 1; }
class_bytes() {
  dev="$1"; classid="$2"
  tc -s class show dev "$dev" | awk -v c="$classid" '\''
    $1 == "class" && $2 == "htb" && $3 == c { hit = 1; next }
    hit && $1 == "Sent" { print $2; exit }
  '\''
}
assert_counter_moves() {
  label="$1"; dev="$2"; classid="$3"; shift 3
  before="$(class_bytes "$dev" "$classid")"; before="${before:-0}"
  "$@" >/tmp/dc-shaping-idem-traffic.out 2>&1 || { cat /tmp/dc-shaping-idem-traffic.out >&2; fail "$label traffic command failed"; }
  after="$(class_bytes "$dev" "$classid")"; after="${after:-0}"
  [ "$after" -gt "$before" ] || fail "$label did not move $dev $classid: before=$before after=$after"
}

[ "$(tc qdisc show dev dcshape-idem | grep -c "qdisc htb 1:")" -eq 1 ] || fail "expected one root HTB on dcshape-idem"
[ "$(tc qdisc show dev dcshape-idem | grep -c "qdisc ingress ffff:")" -eq 1 ] || fail "expected one ingress qdisc on dcshape-idem"
[ "$(tc qdisc show dev ifb_dcs_idem | grep -c "qdisc htb 1:")" -eq 1 ] || fail "expected one root HTB on ifb_dcs_idem"
tc class show dev dcshape-idem | grep -q "class htb 1:20" || fail "missing egress segment aggregate 1:20"
tc class show dev dcshape-idem | grep -q "class htb 20:1036" || fail "missing egress host budget class 20:1036"
tc class show dev dcshape-idem | grep -q "class htb 1036:1" || fail "missing egress host peak class 1036:1"
tc class show dev ifb_dcs_idem | grep -q "class htb 1:20" || fail "missing ingress segment aggregate 1:20"
tc class show dev ifb_dcs_idem | grep -q "class htb 20:1036" || fail "missing ingress host budget class 20:1036"
tc class show dev ifb_dcs_idem | grep -q "class htb 1036:1" || fail "missing ingress host peak class 1036:1"

if tc qdisc show dev dcshape-old 2>/dev/null | grep -q "qdisc htb 1:"; then
  fail "stale root HTB remains on old target dcshape-old"
fi
if ip link show dev ifb_dcshape_old >/dev/null 2>&1; then
  fail "stale old IFB remains after clear"
fi

assert_counter_moves "egress" dcshape-idem 20:1036 ping -I dcshape-idem -c 10 -s 800 172.30.32.36
assert_counter_moves "ingress" ifb_dcs_idem 20:1036 sh -c "ip netns exec dcshape-idem-peer ping -c 10 -s 800 172.30.32.1 >/dev/null 2>&1 || true"

printf "%s\n" "openwrt shaping idempotent apply topology/data-plane: ok"
'

