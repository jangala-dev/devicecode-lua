#!/usr/bin/env sh
# Shared environment for the OpenWrt VM integration test lane.
#
# Scripts normally set VM_DIR before sourcing this file. When sourced directly,
# fall back to the directory containing this file if the caller has cd'd here.

if [ -z "${VM_DIR:-}" ]; then
	VM_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
fi

OPENWRT_VERSION="${OPENWRT_VERSION:-24.10.4}"
OPENWRT_SSH_PORT="${OPENWRT_SSH_PORT:-2222}"
OPENWRT_SSH_WAIT_S="${OPENWRT_SSH_WAIT_S:-90}"
OPENWRT_VM_MEM="${OPENWRT_VM_MEM:-512M}"
OPENWRT_VM_CPUS="${OPENWRT_VM_CPUS:-2}"
# Number of additional QEMU user-mode NICs to attach as deterministic WAN
# devices for network/MWAN integration tests. With the management NIC first,
# OpenWrt normally sees these as eth1..ethN.
OPENWRT_VM_WAN_IFACES="${OPENWRT_VM_WAN_IFACES:-3}"
OPENWRT_KVM="${OPENWRT_KVM:-auto}"

# Optional host tap devices for dataplane tests. These are deliberately separate
# from the QEMU user-mode management NIC. Leave empty for the default self-contained
# VM tests, which create veth/ifb devices inside OpenWrt.
# Example: OPENWRT_TAP_IFACES="tap-dc0 tap-dc1"
OPENWRT_TAP_IFACES="${OPENWRT_TAP_IFACES:-}"

# Optional host-side Open vSwitch dataplane fixture.  This is used only by
# explicit OVS/client targets; the default VM suite remains self-contained.
OPENWRT_OVS_BRIDGE="${OPENWRT_OVS_BRIDGE:-brdcint}"
OPENWRT_OVS_TAP_IFACE="${OPENWRT_OVS_TAP_IFACE:-tapdcint}"
OPENWRT_OVS_CLIENT_NS="${OPENWRT_OVS_CLIENT_NS:-dcintc}"
OPENWRT_OVS_CLIENT_HOST_IFACE="${OPENWRT_OVS_CLIENT_HOST_IFACE:-vdcinth}"
# Temporary root-namespace veth peer name. It is moved into the client namespace
# and then renamed to OPENWRT_OVS_CLIENT_NS_IFACE, because common names such as
# eth0 already exist in the devcontainer root namespace.
OPENWRT_OVS_CLIENT_PEER_IFACE="${OPENWRT_OVS_CLIENT_PEER_IFACE:-vdcintp}"
OPENWRT_OVS_CLIENT_NS_IFACE="${OPENWRT_OVS_CLIENT_NS_IFACE:-eth0}"
OPENWRT_OVS_CLIENT_VLAN="${OPENWRT_OVS_CLIENT_VLAN:-100}"
OPENWRT_OVS_CLIENT_CIDR_PREFIX="${OPENWRT_OVS_CLIENT_CIDR_PREFIX:-172.28.100.}"
OPENWRT_OVS_CLIENT_ROUTER="${OPENWRT_OVS_CLIENT_ROUTER:-172.28.100.1}"
OPENWRT_OVS_PUBLIC_DNS_NAME="${OPENWRT_OVS_PUBLIC_DNS_NAME:-openwrt.org}"
OPENWRT_OVS_PUBLIC_WEB_URL="${OPENWRT_OVS_PUBLIC_WEB_URL:-http://example.com/}"

case "$(uname -m)" in
	x86_64|amd64)
		OPENWRT_ARCH="x86_64"
		OPENWRT_TARGET_PATH="x86/64"
		OPENWRT_PREFIX="openwrt-${OPENWRT_VERSION}-x86-64"
		OPENWRT_IMAGE_NAME="${OPENWRT_PREFIX}-generic-ext4-combined.img.gz"
		OPENWRT_QEMU="${OPENWRT_QEMU:-qemu-system-x86_64}"
		;;
	aarch64|arm64)
		OPENWRT_ARCH="aarch64"
		OPENWRT_TARGET_PATH="armsr/armv8"
		OPENWRT_PREFIX="openwrt-${OPENWRT_VERSION}-armsr-armv8"
		OPENWRT_IMAGE_NAME="${OPENWRT_PREFIX}-generic-ext4-combined-efi.img.gz"
		OPENWRT_QEMU="${OPENWRT_QEMU:-qemu-system-aarch64}"
		;;
	*)
		echo "unsupported host architecture: $(uname -m)" >&2
		exit 1
		;;
esac

OPENWRT_BASE_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${OPENWRT_TARGET_PATH}"

OPENWRT_DIR="${VM_DIR}"
OPENWRT_IMAGE_DIR="${OPENWRT_DIR}/images"
OPENWRT_WORK_DIR="${OPENWRT_DIR}/work"
OPENWRT_IMAGE_GZ="${OPENWRT_IMAGE_DIR}/${OPENWRT_IMAGE_NAME}"
OPENWRT_IMAGE_RAW="${OPENWRT_IMAGE_DIR}/${OPENWRT_IMAGE_NAME%.gz}"
OPENWRT_SHA256SUMS_NAME="sha256sums"
OPENWRT_SHA256SUMS="${OPENWRT_IMAGE_DIR}/sha256sums-${OPENWRT_VERSION}-${OPENWRT_ARCH}"
OPENWRT_WORK_DISK="${OPENWRT_WORK_DIR}/openwrt-${OPENWRT_ARCH}.qcow2"
OPENWRT_PID="${OPENWRT_WORK_DIR}/qemu.pid"
OPENWRT_LOG="${OPENWRT_WORK_DIR}/qemu.log"

OPENWRT_PROVISION_MARKER="${OPENWRT_PROVISION_MARKER:-/etc/devicecode-vm-provisioned}"
OPENWRT_PROVISION_FORCE="${OPENWRT_PROVISION_FORCE:-0}"
