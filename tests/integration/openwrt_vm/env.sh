#!/usr/bin/env sh

OPENWRT_VERSION="${OPENWRT_VERSION:-24.10.4}"
OPENWRT_SSH_PORT="${OPENWRT_SSH_PORT:-2222}"
OPENWRT_VM_MEM="${OPENWRT_VM_MEM:-512M}"
OPENWRT_VM_CPUS="${OPENWRT_VM_CPUS:-2}"

case "$(uname -m)" in
	x86_64|amd64)
		OPENWRT_ARCH="x86_64"
		OPENWRT_TARGET_PATH="x86/64"
		OPENWRT_PREFIX="openwrt-${OPENWRT_VERSION}-x86-64"
		OPENWRT_IMAGE_NAME="${OPENWRT_PREFIX}-generic-ext4-combined.img.gz"
		OPENWRT_QEMU="qemu-system-x86_64"
		;;
	aarch64|arm64)
		OPENWRT_ARCH="aarch64"
		OPENWRT_TARGET_PATH="armsr/armv8"
		OPENWRT_PREFIX="openwrt-${OPENWRT_VERSION}-armsr-armv8"
		OPENWRT_IMAGE_NAME="${OPENWRT_PREFIX}-generic-ext4-combined-efi.img.gz"
		OPENWRT_QEMU="qemu-system-aarch64"
		;;
	*)
		echo "unsupported host architecture: $(uname -m)" >&2
		exit 1
		;;
esac

OPENWRT_BASE_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${OPENWRT_TARGET_PATH}"

OPENWRT_DIR="${VM_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}"
OPENWRT_IMAGE_GZ="${OPENWRT_DIR}/images/${OPENWRT_IMAGE_NAME}"
OPENWRT_IMAGE_RAW="${OPENWRT_DIR}/images/${OPENWRT_IMAGE_NAME%.gz}"
OPENWRT_WORK_DISK="${OPENWRT_DIR}/work/openwrt-${OPENWRT_ARCH}.qcow2"
OPENWRT_PID="${OPENWRT_DIR}/work/qemu.pid"
OPENWRT_LOG="${OPENWRT_DIR}/work/qemu.log"
