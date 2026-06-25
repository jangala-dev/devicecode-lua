#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
SSH="$VM_DIR/scripts/ssh"
SCP_TO="$VM_DIR/scripts/scp-to"
FIXTURE="$VM_DIR/fixtures/mwan3-balanced"
REMOTE_FIXTURE="/tmp/devicecode-mwan3-balanced.fixture"

"$SCP_TO" "$FIXTURE" "$REMOTE_FIXTURE"

"$SSH" 'sh -s' <<'REMOTE'
set -eu
MARKER=/tmp/devicecode-mwan3-three-wan-fixture.ok
if [ "${DEVICECODE_MWAN3_FIXTURE_FORCE:-0}" != 1 ] && [ -f "$MARKER" ]; then
	if [ "$(uci -q get network.wan.device 2>/dev/null)" = eth1 ] && \
	   [ "$(uci -q get network.wanb.device 2>/dev/null)" = eth2 ] && \
	   [ "$(uci -q get network.wanc.device 2>/dev/null)" = eth3 ] && \
	   [ -x /etc/init.d/mwan3 ] && \
	   mwan3 status >/tmp/devicecode-mwan-live-status.log 2>&1 && \
	   iptables-save -t mangle | grep -q '^:mwan3_policy_balanced ' && \
	   iptables-save -t mangle | grep -q '^:mwan3_iface_in_wan ' && \
	   iptables-save -t mangle | grep -q '^:mwan3_iface_in_wanb ' && \
	   iptables-save -t mangle | grep -q '^:mwan3_iface_in_wanc '; then
		echo 'three-WAN MWAN3 fixture already installed'
		exit 0
	fi
fi

echo 'installing three-WAN MWAN3 fixture'
for dev in eth1 eth2 eth3; do
	ip link show "$dev" >/dev/null 2>&1 || {
		echo "missing VM WAN interface: $dev" >&2
		echo 'reset/restart the OpenWrt VM with the default OPENWRT_VM_WAN_IFACES=3' >&2
		exit 1
	}
done

uci -q batch <<'EOF'
delete network.wan
set network.wan=interface
set network.wan.device='eth1'
set network.wan.proto='dhcp'
set network.wan.metric='10'

delete network.wanb
set network.wanb=interface
set network.wanb.device='eth2'
set network.wanb.proto='dhcp'
set network.wanb.metric='20'

delete network.wanc
set network.wanc=interface
set network.wanc.device='eth3'
set network.wanc.proto='dhcp'
set network.wanc.metric='30'

commit network
EOF

WAN_ZONE="$({ uci show firewall || true; } | sed -n "s/^\(firewall\.[^=]*\)=zone$/\1/p" | while read sec; do [ "$(uci -q get "$sec.name")" = wan ] && echo "$sec" && break; done)"
[ -n "$WAN_ZONE" ] || { echo 'wan firewall zone not found' >&2; exit 1; }
uci -q delete "$WAN_ZONE.network" || true
uci add_list "$WAN_ZONE.network=wan"
uci add_list "$WAN_ZONE.network=wanb"
uci add_list "$WAN_ZONE.network=wanc"
uci commit firewall

cp /tmp/devicecode-mwan3-balanced.fixture /etc/config/mwan3

/etc/init.d/network reload >/tmp/devicecode-mwan-live-network.log 2>&1 || { cat /tmp/devicecode-mwan-live-network.log; exit 1; }
/etc/init.d/firewall restart >/tmp/devicecode-mwan-live-firewall.log 2>&1 || { cat /tmp/devicecode-mwan-live-firewall.log; exit 1; }
/etc/init.d/mwan3 enable >/tmp/devicecode-mwan-live-enable.log 2>&1 || true
/etc/init.d/mwan3 restart >/tmp/devicecode-mwan-live-restart.log 2>&1 || { cat /tmp/devicecode-mwan-live-restart.log; exit 1; }
sleep 2

mwan3 status >/tmp/devicecode-mwan-live-status.log 2>&1 || { cat /tmp/devicecode-mwan-live-status.log; exit 1; }
touch "$MARKER"
iptables-save -t mangle | grep -q '^:mwan3_policy_balanced '
iptables-save -t mangle | grep -q '^:mwan3_iface_in_wan '
iptables-save -t mangle | grep -q '^:mwan3_iface_in_wanb '
iptables-save -t mangle | grep -q '^:mwan3_iface_in_wanc '
REMOTE
