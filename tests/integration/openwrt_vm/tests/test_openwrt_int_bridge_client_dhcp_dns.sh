#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(CDPATH= cd -- "$VM_DIR/../../.." && pwd)"
SSH="$VM_DIR/scripts/ssh"
SCP_TO="$VM_DIR/scripts/scp-to"
WAIT_SSH="$VM_DIR/scripts/wait-ssh"
REMOTE="/tmp/devicecode-int-bridge-client-dhcp-dns"
WORK="$VM_DIR/work/int-bridge-client-dhcp-dns"

# shellcheck disable=SC1091
. "$VM_DIR/env.sh"

as_root() {
	if [ "$(id -u)" -eq 0 ]; then
		"$@"
	elif command -v sudo >/dev/null 2>&1; then
		sudo "$@"
	else
		echo "int bridge client DHCP/DNS test: need root privileges for: $*" >&2
		exit 1
	fi
}

fail() {
	echo "int bridge client DHCP/DNS test: $*" >&2
	dump_diag || true
	exit 1
}

ns_exec() {
	as_root ip netns exec "$OPENWRT_CLIENT_NS" "$@"
}

find_udhcpc() {
	if command -v udhcpc >/dev/null 2>&1; then
		printf '%s\n' "$(command -v udhcpc)"
		return 0
	fi
	if command -v busybox >/dev/null 2>&1 && busybox udhcpc --help >/dev/null 2>&1; then
		printf '%s\n' "$(command -v busybox) udhcpc"
		return 0
	fi
	return 1
}

host_has_ns() {
	ip netns list 2>/dev/null | awk '{print $1}' | grep -qx "$OPENWRT_CLIENT_NS"
}

dump_diag() {
	echo "--- host bridge/client diagnostics ---" >&2
	ip -br link show dev "$OPENWRT_CLIENT_TAP" >&2 2>/dev/null || true
	ip -br link show dev "$OPENWRT_CLIENT_HOST_IFACE" >&2 2>/dev/null || true
	if host_has_ns; then
		as_root ip netns exec "$OPENWRT_CLIENT_NS" ip -br addr >&2 2>/dev/null || true
		as_root ip netns exec "$OPENWRT_CLIENT_NS" ip route >&2 2>/dev/null || true
	fi
	if ip link show dev "$OPENWRT_CLIENT_BRIDGE" >/dev/null 2>&1; then
		ip -d link show dev "$OPENWRT_CLIENT_BRIDGE" >&2 2>/dev/null || true
		bridge vlan show dev "$OPENWRT_CLIENT_TAP" >&2 2>/dev/null || true
		bridge vlan show dev "$OPENWRT_CLIENT_HOST_IFACE" >&2 2>/dev/null || true
		bridge link show master "$OPENWRT_CLIENT_BRIDGE" >&2 2>/dev/null || true
	fi
	echo "--- OpenWrt int diagnostics ---" >&2
	"$SSH" 'set +e
		ip -br link show
		ip -br addr show
		bridge link show 2>/dev/null
		echo "### link counters"; ip -s link show dev eth4 2>/dev/null; ip -s link show dev vl-int 2>/dev/null; ip -s link show dev br-int 2>/dev/null
		echo "### bridge fdb br-int"; bridge fdb show br br-int 2>/dev/null || true
		echo "### route"; ip route
		echo "### ip_forward"; cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
		echo "### /etc/config/network"; sed -n "1,260p" /etc/config/network
		echo "### /etc/config/dhcp"; sed -n "1,260p" /etc/config/dhcp
		echo "### /etc/config/firewall"; sed -n "1,320p" /etc/config/firewall
		echo "### fw4 check"; fw4 check 2>&1 || true
		echo "### nft fw4 forward/srcnat"; nft list chain inet fw4 forward 2>&1 || true; nft list chain inet fw4 srcnat 2>&1 || true
		echo "### dnsmasq processes"; ps w | grep "[d]nsmasq" || true
		echo "### UDP listeners"; (ss -lunp 2>/dev/null || netstat -lunp 2>/dev/null || true) | grep -E ":(53|67)\b|dnsmasq" || true
		echo "### dnsmasq generated"; for f in /var/etc/dnsmasq.conf* /tmp/etc/dnsmasq.conf*; do [ -f "$f" ] && { echo "### $f"; sed -n "1,220p" "$f"; }; done
		echo "### captured DHCP on br-int"; cat /tmp/dcint-dhcp-br-int.txt 2>/dev/null || true
		echo "### dnsmasq/netifd/firewall log"; logread -e dnsmasq -e netifd -e firewall -e fw4 | tail -n 220
	' >&2 2>/dev/null || true
	echo "--- end diagnostics ---" >&2
}

wait_for_host() {
	label="$1"
	timeout="$2"
	shift 2
	deadline=$(( $(date +%s) + timeout ))
	while [ "$(date +%s)" -le "$deadline" ]; do
		if "$@" >/dev/null 2>&1; then return 0; fi
		sleep 1
	done
	fail "timeout waiting for host $label"
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

host_has_ns || fail "missing host network namespace $OPENWRT_CLIENT_NS; run scripts/setup-bridge-client-fabric first"
ip link show dev "$OPENWRT_CLIENT_TAP" >/dev/null 2>&1 || fail "missing tap $OPENWRT_CLIENT_TAP; run VM with OPENWRT_TAP_IFACES=$OPENWRT_CLIENT_TAP"
ip link show dev "$OPENWRT_CLIENT_BRIDGE" >/dev/null 2>&1 || fail "missing host client bridge $OPENWRT_CLIENT_BRIDGE"
bridge vlan show dev "$OPENWRT_CLIENT_TAP" | grep -q " $OPENWRT_CLIENT_VLAN" || fail "tap $OPENWRT_CLIENT_TAP is not trunking VLAN $OPENWRT_CLIENT_VLAN"
bridge vlan show dev "$OPENWRT_CLIENT_HOST_IFACE" | grep -q " $OPENWRT_CLIENT_VLAN" || fail "client host veth $OPENWRT_CLIENT_HOST_IFACE is not an access port for VLAN $OPENWRT_CLIENT_VLAN"

GUEST_TRUNK_IFACE="eth$((OPENWRT_VM_WAN_IFACES + 1))"
mkdir -p "$WORK"
cat > "$WORK/run_openwrt_int_bridge_client_config.lua" <<'LUA'
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
local vlan = tonumber(os.getenv('DEVICECODE_TEST_INT_VLAN') or '100') or 100

local intent = {
  schema = 'devicecode.net.intent/1',
  rev = 1002024,
  generation = 1002024,
  segments = {
    lan = {
      kind = 'lan',
      addressing = { ipv4 = { mode = 'static', cidr = '192.168.1.1/24' } },
      dhcp = { enabled = true, start = 100, limit = 150, leasetime = '12h' },
      dns = { local_server = true, domain = 'vm.bigbox.test' },
      firewall = { zone = 'lan' },
    },
    int = {
      kind = 'system', protected = true,
      vlan = { id = vlan },
      addressing = { ipv4 = { mode = 'static', cidr = '172.28.100.1/24' } },
      dhcp = { enabled = true, start = 10, limit = 240, leasetime = '12h' },
      dns = { local_server = true, domain = 'bigbox.home' },
      firewall = { zone = 'lan' },
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
  dns = {
    enabled = true,
    domain = 'bigbox.home',
    upstreams = { '1.1.1.1', '8.8.8.8' },
    cache = { size = 1000 },
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
    policies = {
      lan_to_wan = { src = 'lan', dest = 'wan' },
    },
  },
  routing = { routes = {} },
  wan = {},
  
  vpn = {},
  diagnostics = {},
}

fibers.run(function()
  local provider = assert(provider_loader.new({
    provider = 'openwrt',
    debounce_s = 0.01,
    platform = { segment_trunk = { ifname = trunk_ifname, protected = true } },
    run_cmd = function(argv)
      print('int-bridge-client config-only: skipped activation command ' .. table.concat(argv or {}, ' '))
      return true, nil
    end,
    shaper_run_cmd = function(_argv) return true, nil end,
  }, {}))

  local valid = perform(provider:validate_op({ intent = intent }))
  if not (valid and valid.ok == true) then fail('validate failed: ' .. tostring(valid and valid.err)) end
  local result = perform(provider:apply_op({ intent = intent, opts = { generation = 1002024, apply_id = 'int-bridge-client-dhcp-dns' } }))
  if not (result and result.ok == true) then fail('apply failed: ' .. tostring(result and result.err)) end
  local mgr = provider._uci_manager
  wait_until(function()
    local st = mgr and mgr.activation_status and mgr:activation_status() or nil
    return st and (st.state == 'done' or st.state == 'idle')
  end, 5, 'config-only activation runner should be idle')
  provider:terminate('int bridge client DHCP/DNS test configured')
end)

print('openwrt int bridge client config generated: ok')
LUA

"$SSH" "rm -rf '$REMOTE'; mkdir -p '$REMOTE'; ip link show dev '$GUEST_TRUNK_IFACE' >/dev/null"
"$SCP_TO" "$ROOT_DIR/src" "$REMOTE/src"
"$SCP_TO" "$ROOT_DIR/vendor" "$REMOTE/vendor"
"$SCP_TO" "$WORK/run_openwrt_int_bridge_client_config.lua" "$REMOTE/run_openwrt_int_bridge_client_config.lua"
"$SSH" "cd '$REMOTE' && DEVICECODE_TEST_TRUNK_IFACE='$GUEST_TRUNK_IFACE' DEVICECODE_TEST_INT_VLAN='$OPENWRT_CLIENT_VLAN' lua ./run_openwrt_int_bridge_client_config.lua"

"$SSH" '/etc/init.d/network reload' || true
"$WAIT_SSH"
"$SSH" '/etc/init.d/firewall restart'
wait_for_router "br-int" 45 "ip link show dev br-int"
wait_for_router "int address" 45 "ip -4 addr show dev br-int | grep -q '172.28.100.1'"
wait_for_router "vl-int" 45 "ip link show dev vl-int"
wait_for_router "wan default route" 45 "ip route | grep -q '^default .* dev eth1'"
wait_for_router "router public IP egress" 45 "ping -c 1 -W 3 8.8.8.8"
wait_for_router "router public DNS" 45 "nslookup '$OPENWRT_CLIENT_PUBLIC_DNS_NAME' 1.1.1.1 | grep -q '^Name:'"
"$SSH" '/etc/init.d/dnsmasq restart'
wait_for_router "dnsmasq" 45 "pgrep dnsmasq"
sleep 1
wait_for_router "int DNS local record" 20 "nslookup config.bigbox.home 172.28.100.1 | grep -q '192.168.1.1'"
wait_for_router "int DNS public forwarding" 45 "nslookup '$OPENWRT_CLIENT_PUBLIC_DNS_NAME' 172.28.100.1 | grep -q '^Name:'"

# Prove the VLAN trunk/access dataplane independently of dnsmasq before DHCP.
# If this fails, the problem is the VM/client fabric or VLAN delivery into eth4,
# not the OpenWrt DHCP/DNS generator.
as_root ip netns exec "$OPENWRT_CLIENT_NS" ip addr flush dev "$OPENWRT_CLIENT_IFACE" || true
as_root ip netns exec "$OPENWRT_CLIENT_NS" ip route flush dev "$OPENWRT_CLIENT_IFACE" || true
as_root ip netns exec "$OPENWRT_CLIENT_NS" ip addr add "${OPENWRT_CLIENT_CIDR_PREFIX}250/24" dev "$OPENWRT_CLIENT_IFACE"
check_static_tmp="$WORK/static-ping.out"
if ! as_root ip netns exec "$OPENWRT_CLIENT_NS" ping -c 2 -W 2 "$OPENWRT_CLIENT_ROUTER" >"$check_static_tmp" 2>&1; then
	cat "$check_static_tmp" >&2 || true
	fail "static int client could not reach $OPENWRT_CLIENT_ROUTER before DHCP"
fi
rm -f "$check_static_tmp"
as_root ip netns exec "$OPENWRT_CLIENT_NS" ip addr flush dev "$OPENWRT_CLIENT_IFACE" || true
as_root ip netns exec "$OPENWRT_CLIENT_NS" ip route flush dev "$OPENWRT_CLIENT_IFACE" || true

UDHCPC_CMD="$(find_udhcpc || true)"
[ -n "$UDHCPC_CMD" ] || fail "host udhcpc is unavailable; install udhcpc or busybox with udhcpc applet"
LEASE_ENV="$WORK/bridge-client-lease.env"
LEASE_SCRIPT="$WORK/bridge-client-udhcpc.sh"
rm -f "$LEASE_ENV"
cat > "$LEASE_SCRIPT" <<EOF
#!/bin/sh
case "\$1" in
  bound|renew)
    {
      printf "ip='%s'\\n" "\$ip"
      printf "router='%s'\\n" "\$router"
      printf "dns='%s'\\n" "\$dns"
      printf "domain='%s'\\n" "\$domain"
      printf "subnet='%s'\\n" "\$subnet"
    } > '$LEASE_ENV'
    ip addr flush dev "\$interface" 2>/dev/null || true
    ip addr add "\$ip/24" dev "\$interface"
    ip link set "\$interface" up
    if [ -n "\$router" ]; then
      set -- \$router
      ip route replace default via "\$1" dev "\$interface" 2>/dev/null || true
    fi
    ;;
esac
exit 0
EOF
chmod +x "$LEASE_SCRIPT"

as_root ip netns exec "$OPENWRT_CLIENT_NS" ip addr flush dev "$OPENWRT_CLIENT_IFACE" || true
as_root ip netns exec "$OPENWRT_CLIENT_NS" ip route flush dev "$OPENWRT_CLIENT_IFACE" || true
"$SSH" 'rm -f /tmp/dcint-dhcp-br-int.txt; if command -v tcpdump >/dev/null 2>&1; then (tcpdump -ni br-int -e -vv "port 67 or port 68" > /tmp/dcint-dhcp-br-int.txt 2>&1 & echo $! > /tmp/dcint-dhcp-br-int.pid); fi' || true
# shellcheck disable=SC2086
as_root ip netns exec "$OPENWRT_CLIENT_NS" sh -c "$UDHCPC_CMD -i '$OPENWRT_CLIENT_IFACE' -q -n -t 10 -T 1 -s '$LEASE_SCRIPT'" || { "$SSH" 'if [ -f /tmp/dcint-dhcp-br-int.pid ]; then kill $(cat /tmp/dcint-dhcp-br-int.pid) 2>/dev/null || true; fi' || true; fail "host-side bridge client did not obtain an int lease"; }
"$SSH" 'if [ -f /tmp/dcint-dhcp-br-int.pid ]; then kill $(cat /tmp/dcint-dhcp-br-int.pid) 2>/dev/null || true; fi' || true
# Give libc-based tools inside the namespace the same resolver that DHCP handed
# to the client. nslookup below passes the server explicitly, but wget/curl use
# the namespace resolver file.
as_root mkdir -p "/etc/netns/$OPENWRT_CLIENT_NS"
printf 'nameserver %s\n' "$OPENWRT_CLIENT_ROUTER" | as_root tee "/etc/netns/$OPENWRT_CLIENT_NS/resolv.conf" >/dev/null
[ -f "$LEASE_ENV" ] || fail "host-side client lease environment was not captured"
# shellcheck disable=SC1090
. "$LEASE_ENV"
case "$ip" in "$OPENWRT_CLIENT_CIDR_PREFIX"*) ;; *) fail "lease IP $ip is not in ${OPENWRT_CLIENT_CIDR_PREFIX}0/24" ;; esac
case " ${router:-} " in *" $OPENWRT_CLIENT_ROUTER "*) ;; *) fail "router option does not contain $OPENWRT_CLIENT_ROUTER: ${router:-}" ;; esac
case " ${dns:-} " in *" $OPENWRT_CLIENT_ROUTER "*) ;; *) fail "DNS option does not contain $OPENWRT_CLIENT_ROUTER: ${dns:-}" ;; esac

check_ns() {
	label="$1"
	timeout="$2"
	shift 2
	deadline=$(( $(date +%s) + timeout ))
	while [ "$(date +%s)" -le "$deadline" ]; do
		if ns_exec "$@" >/dev/null 2>&1; then return 0; fi
		sleep 1
	done
	fail "$label failed"
}

check_public_dns() {
	label="$1"
	tmp="$WORK/public-dns.out"
	deadline=$(( $(date +%s) + 45 ))
	while [ "$(date +%s)" -le "$deadline" ]; do
		if ns_exec nslookup "$OPENWRT_CLIENT_PUBLIC_DNS_NAME" "$OPENWRT_CLIENT_ROUTER" >"$tmp" 2>&1 && grep -q '^Name:' "$tmp"; then
			rm -f "$tmp"
			return 0
		fi
		sleep 1
	done
	cat "$tmp" >&2 2>/dev/null || true
	rm -f "$tmp"
	fail "$label could not resolve $OPENWRT_CLIENT_PUBLIC_DNS_NAME via $OPENWRT_CLIENT_ROUTER"
}

check_ns "client can ping int router" 20 ping -c 2 -W 2 "$OPENWRT_CLIENT_ROUTER"
if ! ns_exec ping -c 2 -W 2 8.8.8.8 >/dev/null 2>&1; then
	echo "int bridge client DHCP/DNS test: warning: client ICMP to 8.8.8.8 failed; continuing with DNS/TCP checks" >&2
fi
ns_exec nslookup config.bigbox.home "$OPENWRT_CLIENT_ROUTER" | grep -q '192.168.1.1' || fail "client could not resolve config.bigbox.home via int DNS"
check_public_dns "client public DNS"

if command -v wget >/dev/null 2>&1; then
	check_ns "client public HTTP fetch" 45 wget -q -T 10 -O /dev/null "$OPENWRT_CLIENT_PUBLIC_WEB_URL"
elif command -v curl >/dev/null 2>&1; then
	check_ns "client public HTTP fetch" 45 curl -fsSL --max-time 15 -o /dev/null "$OPENWRT_CLIENT_PUBLIC_WEB_URL"
else
	echo "int bridge client DHCP/DNS test: wget/curl unavailable; skipping public HTTP fetch" >&2
fi

printf '%s\n' "openwrt int bridge client DHCP/DNS/public-web: ok"
