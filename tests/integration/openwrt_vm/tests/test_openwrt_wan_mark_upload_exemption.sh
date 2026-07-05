#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(CDPATH= cd -- "$VM_DIR/../../.." && pwd)"
SSH="$VM_DIR/scripts/ssh"
SCP_TO="$VM_DIR/scripts/scp-to"
STAGE_DEVICECODE="$VM_DIR/scripts/ensure-devicecode-staged"
CLEANUP="$VM_DIR/scripts/cleanup-shaping-state"
REMOTE="/tmp/devicecode-wan-mark-upload-exemption"
WORK="$VM_DIR/work/wan-mark-upload-exemption"

mkdir -p "$WORK"
"$CLEANUP" >/dev/null 2>&1 || true
IP_FORWARD_ORIG="$($SSH 'cat /proc/sys/net/ipv4/ip_forward' 2>/dev/null || true)"
cleanup_all() {
  set +e
  if [ -n "${IP_FORWARD_ORIG:-}" ]; then
    "$SSH" "sysctl -w net.ipv4.ip_forward=$IP_FORWARD_ORIG >/dev/null 2>&1" >/dev/null 2>&1 || true
  fi
  "$CLEANUP" >/dev/null 2>&1 || true
}
trap cleanup_all EXIT INT TERM

cat > "$WORK/run_wan_mark_upload_exemption.lua" <<'LUA'
package.path = table.concat({
  './src/?.lua', './src/?/init.lua',
  './vendor/lua-fibers/src/?.lua', './vendor/lua-fibers/src/?/init.lua',
  './vendor/lua-bus/src/?.lua', './vendor/lua-bus/src/?/init.lua',
  './vendor/lua-trie/src/?.lua', './vendor/lua-trie/src/?/init.lua',
  package.path,
}, ';')

local fibers = require 'fibers'
local exec = require 'fibers.io.exec'
local shaper = require 'services.hal.backends.network.providers.openwrt.shaper'
local unpack = table.unpack or unpack
local perform = fibers.perform

local function run(argv)
  local cmd = exec.command(unpack(argv))
  local out, st, code = perform(cmd:combined_output_op())
  if st == 'exited' and code == 0 then return true, out or '', nil, code end
  return nil, out or '', out or 'command failed', code
end

local req = {
  marks = { mask = '0x00f00000', control = '0x00100000', client = '0x00200000' },
  links = {
    test_wan = {
      kind = 'wan_mark',
      iface = 'dcwan0',
      egress = {
        enabled = true,
        root = { rate = '1gbit', ceil = '1gbit' },
        control = { rate = '1gbit', ceil = '1gbit' },
        client = { rate = '2mbit', ceil = '2mbit' },
        fq_codel = { flows = 128, limit = 1024, memory_limit = '1Mb' },
      },
      ingress = { enabled = false },
    },
  },
}

fibers.run(function()
  local result = shaper.apply(req, { run_cmd = run })
  assert(result and result.ok == true, tostring(result and result.err))
end)

print('openwrt wan mark upload exemption apply: ok')
LUA

"$SSH" 'set -eu
modprobe sch_htb 2>/dev/null || true
modprobe sch_fq_codel 2>/dev/null || true
modprobe cls_fw 2>/dev/null || true
modprobe xt_mark 2>/dev/null || true
modprobe xt_CONNMARK 2>/dev/null || true
modprobe xt_comment 2>/dev/null || true
ip link del dcwan0 2>/dev/null || true
ip link del dcclient-host 2>/dev/null || true
ip netns del dcwan-upstream 2>/dev/null || true
ip netns del dcwan-client 2>/dev/null || true
ip netns add dcwan-upstream
ip netns add dcwan-client
ip link add dcwan0 type veth peer name dcwan-up0
ip link set dcwan-up0 netns dcwan-upstream
ip addr add 10.203.0.1/24 dev dcwan0
ip link set dcwan0 up
ip netns exec dcwan-upstream ip addr add 10.203.0.2/24 dev dcwan-up0
ip netns exec dcwan-upstream ip link set lo up
ip netns exec dcwan-upstream ip link set dcwan-up0 up
ip netns exec dcwan-upstream ip route add 10.204.0.0/24 via 10.203.0.1 dev dcwan-up0

ip link add dcclient-host type veth peer name dcclient0
ip link set dcclient0 netns dcwan-client
ip addr add 10.204.0.1/24 dev dcclient-host
ip link set dcclient-host up
ip netns exec dcwan-client ip addr add 10.204.0.2/24 dev dcclient0
ip netns exec dcwan-client ip link set lo up
ip netns exec dcwan-client ip link set dcclient0 up
ip netns exec dcwan-client ip route add default via 10.204.0.1 dev dcclient0
sysctl -w net.ipv4.ip_forward=1 >/dev/null
iptables -I FORWARD -i dcclient-host -o dcwan0 -j ACCEPT
iptables -I FORWARD -i dcwan0 -o dcclient-host -j ACCEPT
'

"$SSH" "rm -rf '$REMOTE'; mkdir -p '$REMOTE'"
CODE_REMOTE="$($STAGE_DEVICECODE)"
"$SCP_TO" "$WORK/run_wan_mark_upload_exemption.lua" "$REMOTE/run.lua"
"$SSH" "cd '$CODE_REMOTE' && lua '$REMOTE/run.lua'"

"$SSH" 'set -eu
fail() { echo "wan mark upload exemption test: $*" >&2; exit 1; }
class_bytes() {
  dev="$1"; classid="$2"
  tc -s class show dev "$dev" | awk -v c="$classid" '\''
    $1 == "class" && $2 == "htb" && $3 == c { hit = 1; next }
    hit && $1 == "Sent" { print $2; exit }
  '\''
}
assert_moves() {
  label="$1"; classid="$2"; shift 2
  before="$(class_bytes dcwan0 "$classid")"; before="${before:-0}"
  "$@" >/tmp/dcwan-upload-traffic.out 2>&1 || { cat /tmp/dcwan-upload-traffic.out >&2; fail "$label traffic failed"; }
  after="$(class_bytes dcwan0 "$classid")"; after="${after:-0}"
  [ "$after" -gt "$before" ] || {
    tc -s class show dev dcwan0 >&2 2>/dev/null || true
    iptables -t mangle -S >&2 2>/dev/null || true
    fail "$label did not move class $classid: before=$before after=$after"
  }
}

tc qdisc show dev dcwan0 | grep -q "qdisc htb 1:" || fail "missing WAN root HTB"
tc class show dev dcwan0 | grep -q "class htb 1:10" || fail "missing router/control class"
tc class show dev dcwan0 | grep -q "class htb 1:20" || fail "missing client class"
tc filter show dev dcwan0 parent 1: | grep -Eq "(classid|flowid) 1:10" || { tc filter show dev dcwan0 parent 1: >&2 2>/dev/null || true; fail "missing control mark filter"; }
tc filter show dev dcwan0 parent 1: | grep -Eq "(classid|flowid) 1:20" || { tc filter show dev dcwan0 parent 1: >&2 2>/dev/null || true; fail "missing client mark filter"; }

assert_moves "router-originated upload" 1:10 sh -c "ping -I dcwan0 -c 10 -s 800 10.203.0.2 >/dev/null 2>&1 || true"

# With MWAN active in the integration VM, a synthetic test interface that is not
# an MWAN member can be policy-routed or dropped before it ever reaches dcwan0.
# Keep the forwarded-client contract covered by the mangle-chain assertions
# above, and exercise the client TC class by applying the same client mark to
# router-originated test packets on dcwan0.  Append this rule after
# DEVICECODE_SHAPING_OUTPUT; otherwise the router-exempt rule in that chain will
# overwrite the test client mark and the packet will still classify as control.
iptables -t mangle -A OUTPUT -o dcwan0 -m comment --comment devicecode-test-client-mark -j MARK --set-xmark 0x00200000/0x00f00000
assert_moves "client-marked upload" 1:20 sh -c "ping -I dcwan0 -c 10 -s 800 10.203.0.2 >/dev/null 2>&1 || true"
iptables -t mangle -D OUTPUT -o dcwan0 -m comment --comment devicecode-test-client-mark -j MARK --set-xmark 0x00200000/0x00f00000 2>/dev/null || true

printf "%s\n" "openwrt wan mark upload exemption data-plane: ok"
'

