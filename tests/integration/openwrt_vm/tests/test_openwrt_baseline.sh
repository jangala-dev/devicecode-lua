#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
SSH="$VM_DIR/scripts/ssh"

"$SSH" 'command -v uci >/dev/null'
"$SSH" 'command -v ip >/dev/null'
"$SSH" 'command -v nft >/dev/null'
"$SSH" 'command -v tc >/dev/null'

"$SSH" 'uci show network >/dev/null'
"$SSH" 'ip link show br-lan >/dev/null'
"$SSH" 'tc qdisc show >/dev/null'
"$SSH" 'nft list ruleset >/dev/null'

"$SSH" '
	set -eu
	ip link del dc_base_a 2>/dev/null || true
	ip link del dc_base_ifb 2>/dev/null || true
	trap "ip link del dc_base_a 2>/dev/null || true; ip link del dc_base_ifb 2>/dev/null || true" EXIT

	ip link add dc_base_a type veth peer name dc_base_b
	ip link set dc_base_a up
	ip link set dc_base_b up
	ip link add dc_base_ifb type ifb
	ip link set dc_base_ifb up

	tc qdisc add dev dc_base_a root handle 1: htb default 10
	tc class add dev dc_base_a parent 1: classid 1:10 htb rate 10mbit ceil 10mbit
	tc qdisc add dev dc_base_a parent 1:10 fq_codel
	tc qdisc show dev dc_base_a | grep -q htb
	tc class show dev dc_base_a | grep -q "1:10"
'

echo "openwrt baseline: ok"
