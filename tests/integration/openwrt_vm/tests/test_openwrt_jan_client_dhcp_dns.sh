#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(CDPATH= cd -- "$VM_DIR/../../.." && pwd)"
SSH="$VM_DIR/scripts/ssh"
SCP_TO="$VM_DIR/scripts/scp-to"
WAIT_SSH="$VM_DIR/scripts/wait-ssh"
REMOTE="/tmp/devicecode-jan-client-dhcp-dns"
WORK="$VM_DIR/work/jan-client-dhcp-dns"

mkdir -p "$WORK"
cat > "$WORK/run_openwrt_jan_client_config.lua" <<'LUA'
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

local intent = {
  schema = 'devicecode.net.intent/1',
  rev = 32024,
  generation = 32024,
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
      dhcp = { enabled = true, start = 10, limit = 240, leasetime = '12h' },
      dns = { local_server = true, domain = 'bigbox.home' },
      firewall = { zone = 'jan' },
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
  shaping = {},
  vpn = {},
  diagnostics = {},
}

fibers.run(function()
  local provider = assert(provider_loader.new({
    provider = 'openwrt',
    debounce_s = 0.01,
    platform = { segment_trunk = { ifname = 'dcjantrunk0', protected = true } },
    -- This lane performs activation explicitly from the shell harness so SSH can
    -- reconnect cleanly after network reload.  Synchronous activation itself is
    -- covered by the provider activation-contract VM test.
    run_cmd = function(argv)
      print('jan-client config-only: skipped activation command ' .. table.concat(argv or {}, ' '))
      return true, nil
    end,
    shaper_run_cmd = function(_argv) return true, nil end,
  }, {}))

  local valid = perform(provider:validate_op({ intent = intent }))
  if not (valid and valid.ok == true) then fail('validate failed: ' .. tostring(valid and valid.err)) end
  local result = perform(provider:apply_op({ intent = intent, opts = { generation = 32024, apply_id = 'jan-client-dhcp-dns' } }))
  if not (result and result.ok == true) then fail('apply failed: ' .. tostring(result and result.err)) end
  local mgr = provider._uci_manager
  wait_until(function()
    local st = mgr and mgr.activation_status and mgr:activation_status() or nil
    return st and (st.state == 'done' or st.state == 'idle')
  end, 5, 'config-only activation runner should be idle')
  provider:terminate('jan client DHCP/DNS test configured')
end)

print('openwrt jan client config generated: ok')
LUA

"$SSH" "rm -rf '$REMOTE'; mkdir -p '$REMOTE'; ip link del dcjantrunk0 2>/dev/null || true; ip link del dcjantrunk0p 2>/dev/null || true; ip link add dcjantrunk0 type veth peer name dcjantrunk0p; ip link set dcjantrunk0 up; ip link set dcjantrunk0p up"
"$SCP_TO" "$ROOT_DIR/src" "$REMOTE/src"
"$SCP_TO" "$ROOT_DIR/vendor" "$REMOTE/vendor"
"$SCP_TO" "$WORK/run_openwrt_jan_client_config.lua" "$REMOTE/run_openwrt_jan_client_config.lua"
"$SSH" "cd '$REMOTE' && lua ./run_openwrt_jan_client_config.lua"

# Activate network in a shell-controlled phase so this test does not depend on
# keeping a long-running SSH command alive across network reload.  dnsmasq is
# restarted inside the client exercise below, after the synthetic Jan client
# link exists; on some OpenWrt VM/kernel combinations dnsmasq will otherwise
# start before the bridge has carrier and will not offer on the synthetic link.
"$SSH" '/etc/init.d/network reload' || true
"$WAIT_SSH"
"$SSH" '/etc/init.d/firewall restart'

"$SSH" 'set -eu

fail() { echo "jan client DHCP/DNS test: $*" >&2; exit 1; }
cleanup() {
  ip netns del dc-jan-client 2>/dev/null || true
  ip link del dc-jan-host 2>/dev/null || true
  rm -f /tmp/dc-jan-lease.env /tmp/dc-jan-udhcpc.sh /tmp/dc-jan-use-default-route
}
trap cleanup EXIT INT TERM

wait_for() {
  label="$1"
  timeout="$2"
  shift 2
  cmd="$*"
  deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -le "$deadline" ]; do
    if sh -c "$cmd" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  fail "timeout waiting for $label"
}

wait_for br-jan 45 "ip link show dev br-jan"
wait_for jan-address 45 "ip -4 addr show dev br-jan | grep -q 172.28.32.1"
wait_for vl-jan 45 "ip link show dev vl-jan"
wait_for wan-address 45 "ip -4 addr show dev eth1 | grep -q '\''inet '\''"
wait_for default-route 45 "ip route | grep -q '\''^default .* dev eth1'\''"

dump_diag() {
  echo "--- jan DHCP/DNS diagnostics ---" >&2
  ip -br link show >&2 2>/dev/null || true
  ip -br addr show br-jan vl-jan dc-jan-host dc-jan-client0 >&2 2>/dev/null || true
  bridge link show >&2 2>/dev/null || true
  echo "--- /etc/config/dhcp ---" >&2
  sed -n "1,220p" /etc/config/dhcp >&2 2>/dev/null || true
  echo "--- generated dnsmasq configs ---" >&2
  for f in /var/etc/dnsmasq.conf* /tmp/etc/dnsmasq.conf*; do
    [ -f "$f" ] || continue
    echo "### $f" >&2
    sed -n "1,220p" "$f" >&2 2>/dev/null || true
  done
  echo "--- dnsmasq processes ---" >&2
  ps w | grep "[d]nsmasq" >&2 2>/dev/null || true
  echo "--- recent dnsmasq/netifd log ---" >&2
  logread -e dnsmasq -e netifd | tail -n 120 >&2 2>/dev/null || true
  echo "--- end diagnostics ---" >&2
}


HAVE_NETNS=0
if ip netns add dc-jan-client >/dev/null 2>&1; then
  HAVE_NETNS=1
  ip netns del dc-jan-client >/dev/null 2>&1 || true
fi

client_exec() {
  if [ "$HAVE_NETNS" = 1 ]; then
    ip netns exec dc-jan-client "$@"
  else
    "$@"
  fi
}

ip link del dc-jan-host 2>/dev/null || true
ip link add dc-jan-host type veth peer name dc-jan-client0
ip link set dc-jan-host master br-jan
ip link set dc-jan-host up

if [ "$HAVE_NETNS" = 1 ]; then
  ip netns add dc-jan-client
  touch /tmp/dc-jan-use-default-route
  ip link set dc-jan-client0 netns dc-jan-client
  client_exec ip link set lo up
  client_exec ip link set dc-jan-client0 up
else
  echo "jan client DHCP/DNS test: ip netns unavailable; using same-namespace veth DHCP fallback" >&2
  ip link set dc-jan-client0 up
fi

# Restart dnsmasq only after the synthetic client-facing bridge port is present.
# This keeps the test robust on VM kernels where an empty bridge does not have
# carrier when dnsmasq first enumerates DHCP-capable interfaces.
/etc/init.d/dnsmasq restart
wait_for dnsmasq 45 "pgrep dnsmasq"
sleep 1

cat > /tmp/dc-jan-udhcpc.sh <<"EOF"
#!/bin/sh
case "$1" in
  bound|renew)
    {
      printf "ip='\''%s'\''\n" "$ip"
      printf "router='\''%s'\''\n" "$router"
      printf "dns='\''%s'\''\n" "$dns"
      printf "domain='\''%s'\''\n" "$domain"
      printf "subnet='\''%s'\''\n" "$subnet"
    } > /tmp/dc-jan-lease.env
    ip addr flush dev "$interface" 2>/dev/null || true
    ip addr add "$ip/24" dev "$interface"
    ip link set "$interface" up
    if [ -f /tmp/dc-jan-use-default-route ] && [ -n "$router" ]; then
      set -- $router
      ip route replace default via "$1" dev "$interface" 2>/dev/null || true
    fi
    ;;
esac
exit 0
EOF
chmod +x /tmp/dc-jan-udhcpc.sh

client_exec udhcpc -i dc-jan-client0 -q -n -t 10 -T 1 -s /tmp/dc-jan-udhcpc.sh || { dump_diag; fail "udhcpc did not obtain a jan lease"; }
[ -f /tmp/dc-jan-lease.env ] || fail "lease environment was not captured"
. /tmp/dc-jan-lease.env
case "$ip" in 172.28.32.*) ;; *) fail "lease IP $ip is not in 172.28.32.0/24" ;; esac
case " ${router:-} " in *" 172.28.32.1 "*) ;; *) fail "router option does not contain 172.28.32.1: ${router:-}" ;; esac
case " ${dns:-} " in *" 172.28.32.1 "*) ;; *) fail "DNS option does not contain 172.28.32.1: ${dns:-}" ;; esac

PUBLIC_DNS_NAME="${DEVICECODE_TEST_PUBLIC_DNS_NAME:-openwrt.org}"
PUBLIC_DNS_UPSTREAM="${DEVICECODE_TEST_PUBLIC_DNS_UPSTREAM:-1.1.1.1}"

check_public_dns() {
  label="$1"; shift
  tmp="/tmp/dc-jan-public-dns.$$"
  deadline=$(( $(date +%s) + 45 ))
  while [ "$(date +%s)" -le "$deadline" ]; do
    if "$@" >"$tmp" 2>&1 && grep -q "^Name:" "$tmp"; then
      rm -f "$tmp"
      return 0
    fi
    sleep 1
  done
  cat "$tmp" >&2 2>/dev/null || true
  rm -f "$tmp"
  fail "$label could not resolve $PUBLIC_DNS_NAME"
}

nslookup config.bigbox.home 172.28.32.1 | grep -q "192.168.1.1" || fail "config.bigbox.home did not resolve via jan DNS"
check_public_dns "VM public DNS via $PUBLIC_DNS_UPSTREAM" nslookup "$PUBLIC_DNS_NAME" "$PUBLIC_DNS_UPSTREAM"

if [ "$HAVE_NETNS" = 1 ]; then
  client_exec nslookup config.bigbox.home 172.28.32.1 | grep -q "192.168.1.1" || fail "client could not resolve config.bigbox.home via jan DNS"
  check_public_dns "jan client public DNS via 172.28.32.1" client_exec nslookup "$PUBLIC_DNS_NAME" 172.28.32.1
else
  # OpenWrt default VM kernels often omit network namespaces.  DHCP above still
  # proves a throwaway veth client can reach dnsmasq over br-jan; this fallback
  # proves the jan dnsmasq instance itself can forward public DNS.
  check_public_dns "jan DNS public forwarding via 172.28.32.1" nslookup "$PUBLIC_DNS_NAME" 172.28.32.1
fi

printf "%s\n" "openwrt jan client DHCP/DNS/public-DNS: ok"
'
