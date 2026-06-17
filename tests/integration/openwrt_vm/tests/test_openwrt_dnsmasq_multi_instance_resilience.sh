#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(CDPATH= cd -- "$VM_DIR/../../.." && pwd)"
SSH="$VM_DIR/scripts/ssh"
SCP_TO="$VM_DIR/scripts/scp-to"
WAIT_SSH="$VM_DIR/scripts/wait-ssh"
REMOTE="/tmp/devicecode-dnsmasq-multi-instance-resilience"
WORK="$VM_DIR/work/dnsmasq-multi-instance-resilience"

# shellcheck disable=SC1091
. "$VM_DIR/env.sh"

fail() {
	echo "openwrt dnsmasq multi-instance resilience test: $*" >&2
	dump_diag || true
	exit 1
}

dump_diag() {
	echo "--- OpenWrt dnsmasq multi-instance diagnostics ---" >&2
	"$SSH" 'set +e
		echo "### link state"; ip -br link show; ip -br addr show
		echo "### /etc/config/network"; sed -n "1,320p" /etc/config/network
		echo "### /etc/config/dhcp"; sed -n "1,360p" /etc/config/dhcp
		echo "### dnsmasq processes"; ps w | grep "[d]nsmasq" || true
		echo "### UDP listeners"; (ss -lunp 2>/dev/null || netstat -lunp 2>/dev/null || true) | grep -E ":(53|67)\\b|dnsmasq" || true
		echo "### dnsmasq generated"; for f in /var/etc/dnsmasq.conf* /tmp/etc/dnsmasq.conf*; do [ -f "$f" ] && { echo "### $f"; sed -n "1,220p" "$f"; }; done
		echo "### dnsmasq log"; logread -e dnsmasq -e netifd | tail -n 260
	' >&2 2>/dev/null || true
	echo "--- end diagnostics ---" >&2
}

wait_for_router() {
	label="$1"
	timeout="$2"
	shift 2
	cmd="$*"
	deadline=$(( $(date +%s) + timeout ))
	while [ "$(date +%s)" -le "$deadline" ]; do
		if "$SSH" "$cmd" >/dev/null 2>&1; then return 0; fi
		sleep 1
	done
	fail "timeout waiting for router $label"
}

GUEST_TRUNK_IFACE="eth$((OPENWRT_VM_WAN_IFACES + 1))"
RESTART_ROUNDS="${OPENWRT_DNSMASQ_RESILIENCE_RESTARTS:-1}"
mkdir -p "$WORK"
cat > "$WORK/run_openwrt_dnsmasq_multi_instance_resilience.lua" <<'LUA'
package.path = table.concat({
  './src/?.lua', './src/?/init.lua',
  './vendor/lua-fibers/src/?.lua', './vendor/lua-fibers/src/?/init.lua',
  './vendor/lua-bus/src/?.lua', './vendor/lua-bus/src/?/init.lua',
  './vendor/lua-trie/src/?.lua', './vendor/lua-trie/src/?/init.lua',
  package.path,
}, ';')

local fibers = require 'fibers'
local sleep = require 'fibers.sleep'
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

local trunk_ifname = os.getenv('DEVICECODE_TEST_TRUNK_IFACE') or 'eth4'

local function vlan_segment(vid, cidr, zone, host_files, domain)
  return {
    kind = 'system', protected = true,
    vlan = { id = vid },
    addressing = { ipv4 = { mode = 'static', cidr = cidr } },
    dhcp = { enabled = true, start = 10, limit = 240, leasetime = '12h' },
    dns = { local_server = true, domain = domain or 'bigbox.home', host_files = host_files or {} },
    firewall = { zone = zone or 'lan' },
  }
end

local intent = {
  schema = 'devicecode.net.intent/1',
  rev = 1102024,
  generation = 1102024,
  segments = {
    lan = {
      kind = 'lan',
      addressing = { ipv4 = { mode = 'static', cidr = '192.168.1.1/24' } },
      dhcp = { enabled = true, start = 100, limit = 150, leasetime = '12h' },
      dns = { local_server = true, domain = 'vm.bigbox.test' },
      firewall = { zone = 'lan' },
    },
    adm = vlan_segment(8, '172.28.8.1/24', 'lan', { 'ads' }, 'adm'),
    jan = vlan_segment(32, '172.28.32.1/24', 'lan', { 'ads', 'adult' }, 'jan'),
    int = vlan_segment(100, '172.28.100.1/24', 'lan', {}, 'int'),
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
  dns = {
    enabled = true,
    domain = 'bigbox.home',
    upstreams = { '1.1.1.1', '8.8.8.8' },
    cache = { size = 1000 },
    host_files = {
      base_dir = '/data/devicecode/dns/hosts',
      addnmount = true,
      sources = {
        ads = { file = 'ads.hosts' },
        adult = { file = 'adult.hosts' },
      },
    },
    records = {
      config = { name = 'config.bigbox.home', address = '192.168.1.1' },
    },
  },
  dhcp = { defaults = { authoritative = true } },
  firewall = {
    defaults = { input = 'REJECT', output = 'ACCEPT', forward = 'REJECT' },
    zones = {
      lan = { input = 'ACCEPT', output = 'ACCEPT', forward = 'REJECT' },
      wan = { input = 'REJECT', output = 'ACCEPT', forward = 'REJECT', masq = true, mtu_fix = true },
    },
    policies = { lan_to_wan = { src = 'lan', dest = 'wan' } },
  },
  routing = { routes = {} },
  wan = {},
  shaping = {},
  vpn = {},
  diagnostics = {},
}

fibers.run(function()
  local provider = assert(provider_loader.new({
    provider = 'openwrt',
    debounce_s = 0.01,
    platform = { segment_trunk = { ifname = trunk_ifname, protected = true } },
    run_cmd = function(argv)
      print('dnsmasq-resilience config-only: skipped activation command ' .. table.concat(argv or {}, ' '))
      return true, nil
    end,
    shaper_run_cmd = function(_argv) return true, nil end,
  }, {}))

  local valid = perform(provider:validate_op({ intent = intent }))
  if not (valid and valid.ok == true) then fail('validate failed: ' .. tostring(valid and valid.err)) end
  local result = perform(provider:apply_op({ intent = intent, opts = { generation = 1102024, apply_id = 'dnsmasq-multi-instance-resilience' } }))
  if not (result and result.ok == true) then fail('apply failed: ' .. tostring(result and result.err)) end
  local mgr = provider._uci_manager
  wait_until(function()
    local st = mgr and mgr.activation_status and mgr:activation_status() or nil
    return st and (st.state == 'done' or st.state == 'idle')
  end, 5, 'config-only activation runner should be idle')
  provider:terminate('dnsmasq multi-instance resilience test configured')
end)

print('openwrt dnsmasq multi-instance config generated: ok')
LUA

"$SSH" "rm -rf '$REMOTE'; mkdir -p '$REMOTE'; ip link show dev '$GUEST_TRUNK_IFACE' >/dev/null"
"$SCP_TO" "$ROOT_DIR/src" "$REMOTE/src"
"$SCP_TO" "$ROOT_DIR/vendor" "$REMOTE/vendor"
"$SCP_TO" "$WORK/run_openwrt_dnsmasq_multi_instance_resilience.lua" "$REMOTE/run_openwrt_dnsmasq_multi_instance_resilience.lua"
"$SSH" "cd '$REMOTE' && DEVICECODE_TEST_TRUNK_IFACE='$GUEST_TRUNK_IFACE' lua ./run_openwrt_dnsmasq_multi_instance_resilience.lua"
"$SSH" 'mkdir -p /data/devicecode/dns/hosts; : > /data/devicecode/dns/hosts/ads.hosts; : > /data/devicecode/dns/hosts/adult.hosts'

"$SSH" '/etc/init.d/network reload' || true
"$WAIT_SSH"
wait_for_router "br-lan" 45 "ip -4 addr show dev br-lan | grep -q '192.168.1.1'"
wait_for_router "br-adm" 45 "ip -4 addr show dev br-adm | grep -q '172.28.8.1'"
wait_for_router "br-jan" 45 "ip -4 addr show dev br-jan | grep -q '172.28.32.1'"
wait_for_router "br-int" 45 "ip -4 addr show dev br-int | grep -q '172.28.100.1'"
"$SSH" '/etc/init.d/firewall restart'

verify_instances_remote='set -eu
fail() { echo "$*" >&2; exit 1; }
insts="$(uci -q show dhcp | sed -n "s/^dhcp\.\([^=]*\)=dnsmasq/\1/p" | sort)"
count="$(printf "%s\n" "$insts" | sed "/^$/d" | wc -l)"
[ "$count" -ge 4 ] || fail "expected at least four dnsmasq instances, got $count: $insts"
listeners="$(ss -lunp 2>/dev/null || netstat -lunp 2>/dev/null || true)"
loopback_owner=""
for inst in $insts; do
  cfg="/var/etc/dnsmasq.conf.$inst"
  [ -f "$cfg" ] || fail "missing generated config $cfg"
  ps w | grep -F "dnsmasq -C $cfg" | grep -qv grep || fail "dnsmasq process for $inst is not running"
  if uci -q get dhcp.$inst.interface | grep -qw int; then
    [ -z "$loopback_owner" ] || fail "multiple loopback owner candidates: $loopback_owner and $inst"
    loopback_owner="$inst"
    if uci -q get dhcp.$inst.notinterface | grep -qw lo; then fail "int dnsmasq $inst unexpectedly excludes loopback"; fi
    if grep -q "^except-interface=lo$" "$cfg"; then fail "int dnsmasq $cfg unexpectedly contains except-interface=lo"; fi
  else
    uci -q get dhcp.$inst.notinterface | grep -qw lo || fail "dnsmasq $inst does not exclude loopback"
    grep -q "^except-interface=lo$" "$cfg" || fail "$cfg does not contain except-interface=lo"
  fi
done
[ -n "$loopback_owner" ] || fail "no int dnsmasq loopback owner found"
printf "%s\n" "$listeners" | grep -q "127.0.0.1:53" || fail "no DNS listener on 127.0.0.1:53 for loopback owner $loopback_owner: $listeners"
for spec in \
  "lan 192.168.1.1 br-lan" \
  "adm 172.28.8.1 br-adm" \
  "jan 172.28.32.1 br-jan" \
  "int 172.28.100.1 br-int"
do
  set -- $spec
  name="$1"; ip="$2"; dev="$3"
  ip -4 addr show dev "$dev" | grep -q "$ip" || fail "$dev does not have $ip"
  printf "%s\n" "$listeners" | grep -q "$ip:53" || fail "no DNS listener on $ip:53 for $name"
  nslookup config.bigbox.home "$ip" | grep -q "192.168.1.1" || fail "$name DNS local record failed via $ip"
done
'

restart_round=0
while [ "$restart_round" -lt "$RESTART_ROUNDS" ]; do
	restart_round=$((restart_round + 1))
	"$SSH" '/etc/init.d/dnsmasq restart'
	wait_for_router "all dnsmasq instances after restart $restart_round" 45 "$verify_instances_remote"
	# Give crashes caused by delayed bind conflicts a chance to surface.
	sleep "${OPENWRT_DNSMASQ_RESILIENCE_SETTLE_S:-1}"
	wait_for_router "all dnsmasq instances still alive after restart $restart_round" 20 "$verify_instances_remote"
done

# Include a network reload cycle because netifd can briefly remove/recreate the
# bridge/vlan addresses that dnsmasq binds to.  The instance set must recover
# deterministically afterwards.
"$SSH" '/etc/init.d/network reload' || true
"$WAIT_SSH"
wait_for_router "br-adm after network reload" 45 "ip -4 addr show dev br-adm | grep -q '172.28.8.1'"
wait_for_router "br-jan after network reload" 45 "ip -4 addr show dev br-jan | grep -q '172.28.32.1'"
wait_for_router "br-int after network reload" 45 "ip -4 addr show dev br-int | grep -q '172.28.100.1'"
"$SSH" '/etc/init.d/dnsmasq restart'
wait_for_router "all dnsmasq instances after network reload" 45 "$verify_instances_remote"
sleep "${OPENWRT_DNSMASQ_RESILIENCE_SETTLE_S:-1}"
wait_for_router "all dnsmasq instances stayed up after network reload" 20 "$verify_instances_remote"

printf '%s\n' "openwrt dnsmasq multi-instance resilience: ok"
