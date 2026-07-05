#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(CDPATH= cd -- "$VM_DIR/../../.." && pwd)"
SSH="$VM_DIR/scripts/ssh"
SCP_TO="$VM_DIR/scripts/scp-to"
STAGE_DEVICECODE="$VM_DIR/scripts/ensure-devicecode-staged"
WAIT_SSH="$VM_DIR/scripts/wait-ssh"
CLEANUP="$VM_DIR/scripts/cleanup-shaping-state"
REMOTE="/tmp/devicecode-jan-client-per-host-shaping"
WORK="$VM_DIR/work/jan-client-per-host-shaping"

CONFIG_STATE="/tmp/devicecode-jan-client-per-host-shaping-config-backup"
CONFIG_BACKED_UP=0

backup_config() {
  "$SSH" "CONFIG_STATE='$CONFIG_STATE' sh -s" <<'REMOTE_BACKUP'
set -eu
rm -rf "$CONFIG_STATE"
mkdir -p "$CONFIG_STATE"
: > "$CONFIG_STATE/present"
: > "$CONFIG_STATE/absent"
for name in network dhcp firewall mwan3; do
  if [ -e "/etc/config/$name" ]; then
    cp -a "/etc/config/$name" "$CONFIG_STATE/$name"
    echo "$name" >> "$CONFIG_STATE/present"
  else
    echo "$name" >> "$CONFIG_STATE/absent"
  fi
done
REMOTE_BACKUP
  CONFIG_BACKED_UP=1
}

restore_config() {
  [ "${CONFIG_BACKED_UP:-0}" = 1 ] || return 0
  echo "[jan-shaping] restoring saved OpenWrt config" >&2
  # Do not run network reload synchronously over the same SSH session: reloading
  # the management network can leave the client waiting on a half-closed
  # connection.  Restore the files synchronously, then launch network/firewall
  # activation in the background and wait for SSH to come back.
  "$SSH" "CONFIG_STATE='$CONFIG_STATE' RESTORE_ACTIVATE='${DEVICECODE_RESTORE_ACTIVATE:-1}' sh -s" <<'REMOTE_RESTORE'
set +e
if [ -d "$CONFIG_STATE" ]; then
  while read name; do
    [ -n "$name" ] && [ -e "$CONFIG_STATE/$name" ] && cp -a "$CONFIG_STATE/$name" "/etc/config/$name"
  done < "$CONFIG_STATE/present"
  while read name; do
    [ -n "$name" ] && rm -f "/etc/config/$name"
  done < "$CONFIG_STATE/absent"
  if [ "${RESTORE_ACTIVATE:-1}" = 1 ]; then
    (
      sleep 1
      /etc/init.d/network reload >/tmp/devicecode-jan-shaping-restore-network.log 2>&1
      /etc/init.d/firewall restart >/tmp/devicecode-jan-shaping-restore-firewall.log 2>&1
    ) </dev/null >/tmp/devicecode-jan-shaping-restore-wrapper.log 2>&1 &
    echo restore-launched
  else
    echo restore-files-only
  fi
fi
REMOTE_RESTORE
  if [ "${DEVICECODE_RESTORE_ACTIVATE:-1}" = 1 ]; then
    sleep 1
    "$WAIT_SSH" >/dev/null 2>&1 || true
  fi
}

cleanup_all() {
  set +e
  echo "[jan-shaping] cleaning shaping test state" >&2
  "$CLEANUP" >/dev/null 2>&1 || true
  restore_config || true
}

mkdir -p "$WORK"
if [ "${DC_SHAPING_CLEANUP_DISABLED:-0}" != 1 ]; then
  backup_config
  trap cleanup_all EXIT INT TERM
fi
cat > "$WORK/run_openwrt_jan_shaping_config.lua" <<'LUA'
package.path = table.concat({
  './src/?.lua', './src/?/init.lua',
  './vendor/lua-fibers/src/?.lua', './vendor/lua-fibers/src/?/init.lua',
  './vendor/lua-bus/src/?.lua', './vendor/lua-bus/src/?/init.lua',
  './vendor/lua-trie/src/?.lua', './vendor/lua-trie/src/?/init.lua',
  package.path,
}, ';')

local fibers = require 'fibers'
local sleep = require 'fibers.sleep'
local exec = require 'fibers.io.exec'
local unpack = table.unpack or unpack
local provider_loader = require 'services.hal.backends.network.provider'
local perform = fibers.perform

local function fail(msg) error(msg, 2) end
local function wait_until(pred, timeout_s, label)
  local deadline = fibers.now() + (timeout_s or 1)
  while fibers.now() < deadline do
    if pred() then return true end
    perform(sleep.sleep_op(0.05))
  end
  if pred() then return true end
  fail(label or 'condition was not satisfied before timeout')
end

local function jan_intent(shaping_enabled)
  return {
    schema = 'devicecode.net.intent/1',
    rev = shaping_enabled and 32037 or 32036,
    generation = shaping_enabled and 32037 or 32036,
    segments = {
      lan = {
        kind = 'lan',
        addressing = { ipv4 = { mode = 'static', cidr = '192.168.1.1/24' } },
        dhcp = { enabled = true, start = 100, limit = 150, leasetime = '12h' },
        dns = { local_server = true, domain = 'vm.bigbox.test' },
        firewall = { zone = 'lan' },
      },
      jan = {
        kind = 'user',
        vlan = { id = 32 },
        addressing = { ipv4 = { mode = 'static', cidr = '172.28.32.1/24' } },
        dhcp = { enabled = false },
        dns = { local_server = true, domain = 'bigbox.home' },
        firewall = { zone = 'jan' },
        shaping = shaping_enabled and {
          download = { limit = '8mbit' },
          upload = { limit = '8mbit' },
          host_default = {
            mode = 'budgeted_peak',
            all_hosts = true,
            download = { sustained_rate = '2mbit', peak_rate = '2mbit', burst_budget = '100k' },
            upload = { sustained_rate = '2mbit', peak_rate = '2mbit', burst_budget = '100k' },
            fq_codel = { flows = 1024, limit = 10240 },
          },
        } or {},
      },
      wan = { kind = 'wan', firewall = { zone = 'wan' } },
    },
    interfaces = {
      lan = {
        kind = 'bridge', role = 'lan', segment = 'lan', members = { 'eth0' },
        addressing = { ipv4 = { mode = 'static', cidr = '192.168.1.1/24' } },
        firewall = { zone = 'lan' },
      },
      wan = {
        kind = 'ethernet', role = 'wan', segment = 'wan', endpoint = { ifname = 'eth1' },
        addressing = { ipv4 = { mode = 'dhcp', peerdns = false } },
        dhcp = { enabled = false },
        firewall = { zone = 'wan' },
      },
    },
    dns = { enabled = true, domain = 'bigbox.home', upstreams = { '1.1.1.1' }, cache = { size = 1000 } },
    dhcp = { defaults = { authoritative = true } },
    firewall = {
      defaults = { input = 'REJECT', output = 'ACCEPT', forward = 'REJECT' },
      zones = {
        lan = { input = 'ACCEPT', output = 'ACCEPT', forward = 'REJECT' },
        jan = { input = 'ACCEPT', output = 'ACCEPT', forward = 'REJECT' },
        wan = { input = 'REJECT', output = 'ACCEPT', forward = 'REJECT', masq = true, mtu_fix = true },
      },
      policies = {
        lan_to_wan = { src = 'lan', dest = 'wan' },
        jan_to_wan = { src = 'jan', dest = 'wan' },
      },
    },
    routing = { routes = {} },
    wan = {},
    vpn = {}, diagnostics = {},
  }
end

local mode = arg and arg[1] or 'config'

local function real_run_cmd(argv)
  local cmd = exec.command(unpack(argv or {}))
  local out, st, code, sig, err = perform(cmd:combined_output_op())
  if st == 'exited' and code == 0 then return true, out or '', nil, code, st, sig end
  return nil, out or '', err or out or 'command failed', code, st, sig
end

local provider = assert(provider_loader.new({
  provider = 'openwrt',
  debounce_s = 0.01,
  shaping_target_timeout_s = 5,
  platform = { segment_trunk = { ifname = 'dcjantrunk0', protected = true } },
  -- The shell harness owns network activation so SSH can reconnect cleanly.
  -- Structural activation remains skipped, but the shaping lane must run real
  -- ip/tc commands after br-jan exists; otherwise the data-plane assertions only
  -- test the provider's dry-run result.
  run_cmd = function(argv)
    print('jan-shaping config lane: skipped activation command ' .. table.concat(argv or {}, ' '))
    return true, nil
  end,
  shaper_run_cmd = real_run_cmd,
}, {}))

fibers.run(function()
  local shaping_enabled = (mode == 'shape')
  local result = perform(provider:apply_op({
    intent = jan_intent(shaping_enabled),
    opts = { generation = shaping_enabled and 32037 or 32036, apply_id = 'jan-client-per-host-shaping-' .. mode },
  }))
  if not (result and result.ok == true) then fail('apply failed: ' .. tostring(result and result.err)) end
  if shaping_enabled then
    if not (result.shaping and result.shaping.ok == true) then fail('shaping result missing') end
    if not (result.shaping.links and result.shaping.links.jan and result.shaping.links.jan.iface == 'br-jan') then
      fail('jan shaping should target br-jan, got ' .. tostring(result.shaping and result.shaping.links and result.shaping.links.jan and result.shaping.links.jan.iface))
    end
  else
    local mgr = provider._uci_manager
    wait_until(function()
      local st = mgr and mgr.activation_status and mgr:activation_status() or nil
      return st and (st.state == 'done' or st.state == 'idle')
    end, 5, 'config-only activation runner should be idle')
  end
  provider:terminate('jan per-host shaping test ' .. mode)
end)

print('openwrt jan per-host shaping ' .. mode .. ': ok')
LUA

"$SSH" "rm -rf '$REMOTE'; mkdir -p '$REMOTE'; ip netns del dc-jan-shape-client 2>/dev/null || true; ip link del dc-jan-host 2>/dev/null || true; ip link del dcjantrunk0 2>/dev/null || true; ip link del dcjantrunk0p 2>/dev/null || true; ip link add dcjantrunk0 type veth peer name dcjantrunk0p; ip link set dcjantrunk0 up; ip link set dcjantrunk0p up"
CODE_REMOTE="$($STAGE_DEVICECODE)"
"$SCP_TO" "$WORK/run_openwrt_jan_shaping_config.lua" "$REMOTE/run_openwrt_jan_shaping_config.lua"
"$SSH" "cd '$CODE_REMOTE' && lua '$REMOTE/run_openwrt_jan_shaping_config.lua' config"

"$SSH" '(/etc/init.d/network reload >/tmp/devicecode-jan-shaping-network.log 2>&1; /etc/init.d/firewall restart >/tmp/devicecode-jan-shaping-firewall.log 2>&1) </dev/null >/tmp/devicecode-jan-shaping-activation.log 2>&1 &' || true
"$WAIT_SSH"

set +e
"$SSH" 'set -eu

fail() { echo "jan client per-host shaping test: $*" >&2; exit 1; }
cleanup() {
  ip netns del dc-jan-shape-client 2>/dev/null || true
  ip link del dc-jan-host 2>/dev/null || true
}
trap cleanup EXIT INT TERM

wait_for() {
  label="$1"; timeout="$2"; shift 2
  cmd="$*"
  deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -le "$deadline" ]; do
    if sh -c "$cmd" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  fail "timeout waiting for $label"
}

modprobe ifb 2>/dev/null || true
modprobe sch_htb 2>/dev/null || true
modprobe sch_ingress 2>/dev/null || true
modprobe sch_fq_codel 2>/dev/null || true
modprobe cls_u32 2>/dev/null || true
modprobe act_mirred 2>/dev/null || true

wait_for br-jan 45 "ip link show dev br-jan"
wait_for jan-address 45 "ip -4 addr show dev br-jan | grep -q 172.28.32.1"
wait_for vl-jan 45 "ip link show dev vl-jan"

if ! ip netns add dc-jan-shape-client >/dev/null 2>&1; then
  echo "jan client per-host shaping test: SKIP: network namespaces unavailable; cannot generate unambiguous client data-plane traffic" >&2
  exit 77
fi
ip netns del dc-jan-shape-client >/dev/null 2>&1 || true
'
rc="$?"
set -e
if [ "$rc" -ne 0 ]; then
  if [ "$rc" -eq 77 ]; then exit 0; fi
  exit "$rc"
fi

# Apply shaping only after br-jan exists.  This proves the provider-derived
# segment shaping target is the bridge data device, not the VLAN member.
"$SSH" "cd '$CODE_REMOTE' && lua '$REMOTE/run_openwrt_jan_shaping_config.lua' shape"

"$SSH" 'set -eu

fail() { echo "jan client per-host shaping test: $*" >&2; exit 1; }
cleanup() {
  ip netns del dc-jan-shape-client 2>/dev/null || true
  ip link del dc-jan-host 2>/dev/null || true
}
trap cleanup EXIT INT TERM

class_bytes() {
  dev="$1"
  classid="$2"
  tc -s class show dev "$dev" | awk -v c="$classid" '\''
    $1 == "class" && $2 == "htb" && $3 == c { hit = 1; next }
    hit && $1 == "Sent" { print $2; exit }
  '\''
}

assert_class_exists() {
  dev="$1"; classid="$2"
  tc class show dev "$dev" | grep -q "class htb $classid" || fail "$dev missing class $classid"
}

assert_counter_moves() {
  label="$1"; dev="$2"; classid="$3"; shift 3
  before="$(class_bytes "$dev" "$classid")"
  before="${before:-0}"
  "$@" >/tmp/dc-jan-shaping-traffic.out 2>&1 || {
    cat /tmp/dc-jan-shaping-traffic.out >&2 2>/dev/null || true
    fail "$label traffic command failed"
  }
  after="$(class_bytes "$dev" "$classid")"
  after="${after:-0}"
  [ "$after" -gt "$before" ] || {
    echo "--- tc class $dev ---" >&2
    tc -s class show dev "$dev" >&2 2>/dev/null || true
    echo "--- tc filter br-jan parent 1: ---" >&2
    tc -s filter show dev br-jan parent 1: >&2 2>/dev/null || true
    echo "--- tc filter br-jan ingress ---" >&2
    tc -s filter show dev br-jan parent ffff: >&2 2>/dev/null || true
    fail "$label did not move $dev class $classid counter: before=$before after=$after"
  }
}

ip netns del dc-jan-shape-client 2>/dev/null || true
ip link del dc-jan-host 2>/dev/null || true
ip link add dc-jan-host type veth peer name dc-jan-client0
ip link set dc-jan-host master br-jan
ip link set dc-jan-host up
ip netns add dc-jan-shape-client
ip link set dc-jan-client0 netns dc-jan-shape-client
ip netns exec dc-jan-shape-client ip link set lo up
ip netns exec dc-jan-shape-client ip link set dc-jan-client0 up
ip netns exec dc-jan-shape-client ip addr add 172.28.32.36/24 dev dc-jan-client0
ip netns exec dc-jan-shape-client ip route replace default via 172.28.32.1 dev dc-jan-client0

# Confirm the shaping hierarchy is on the bridge-facing segment device.  The old
# bug installed this tree on vl-jan, which would leave these assertions failing.
tc qdisc show dev br-jan | grep -q "qdisc htb 1:" || fail "br-jan does not have root HTB shaping qdisc"
tc qdisc show dev ifb_br_jan | grep -q "qdisc htb 1:" || fail "ifb_br_jan does not have root HTB shaping qdisc"
assert_class_exists br-jan 1:20
assert_class_exists br-jan 20:1036
assert_class_exists br-jan 1036:1
assert_class_exists ifb_br_jan 1:20
assert_class_exists ifb_br_jan 20:1036
assert_class_exists ifb_br_jan 1036:1
if tc qdisc show dev vl-jan 2>/dev/null | grep -q "qdisc htb 1:"; then
  fail "stale shaping qdisc remains on vl-jan"
fi
if tc qdisc show dev ifb_vl_jan 2>/dev/null | grep -q "qdisc htb 1:"; then
  fail "stale shaping qdisc remains on ifb_vl_jan"
fi

assert_counter_moves "router-to-client" br-jan 20:1036 ping -I br-jan -c 20 -s 1200 172.28.32.36
assert_counter_moves "client-to-router" ifb_br_jan 20:1036 ip netns exec dc-jan-shape-client ping -c 20 -s 1200 172.28.32.1

printf "%s\n" "openwrt jan client per-host shaping data-plane: ok"
'

