#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
SSH="$VM_DIR/scripts/ssh"

run() {
	"$SSH" "$@"
}

run '
	set -eu

	cleanup() {
		ip link del dc-veth-a 2>/dev/null || true
		ip link del dc-ifb0 2>/dev/null || true
	}
	trap cleanup EXIT
	cleanup

	echo "[openwrt-vm] checking kernel modules"
	modprobe veth 2>/dev/null || true
	modprobe ifb 2>/dev/null || true
	modprobe sch_htb 2>/dev/null || true
	modprobe sch_ingress 2>/dev/null || true
	modprobe sch_fq_codel 2>/dev/null || true
	modprobe cls_u32 2>/dev/null || true
	modprobe act_mirred 2>/dev/null || true

	echo "[openwrt-vm] creating veth"
	ip link add dc-veth-a type veth peer name dc-veth-b
	ip link set dc-veth-a up
	ip link set dc-veth-b up

	echo "[openwrt-vm] adding root htb"
	tc qdisc add dev dc-veth-a root handle 1: htb default 10

	echo "[openwrt-vm] adding htb class"
	tc class add dev dc-veth-a parent 1: classid 1:10 htb rate 10mbit ceil 10mbit

	echo "[openwrt-vm] adding fq_codel"
	tc qdisc add dev dc-veth-a parent 1:10 fq_codel

	echo "[openwrt-vm] adding ifb"
	ip link add dc-ifb0 type ifb
	ip link set dc-ifb0 up

	echo "[openwrt-vm] adding ingress"
	tc qdisc add dev dc-veth-b ingress

	echo "[openwrt-vm] tc state"
	tc qdisc show dev dc-veth-a
	tc class show dev dc-veth-a
	tc qdisc show dev dc-veth-b

	echo "openwrt tc/veth baseline: ok"
'
