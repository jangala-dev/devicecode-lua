#!/usr/bin/env sh
set -eu

echo "[devcontainer] preparing OpenWrt VM test tools"

if command -v apt-get >/dev/null 2>&1; then
	sudo apt-get update
	sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
		curl \
		ca-certificates \
		gzip \
		openssh-client \
		rsync \
		socat \
		qemu-system-x86 \
		qemu-system-arm \
		qemu-utils \
		ovmf \
		qemu-efi-aarch64 \
		make \
		iproute2 \
		iputils-ping \
		busybox \
		dnsutils \
		wget \
		tcpdump
elif command -v apk >/dev/null 2>&1; then
	sudo apk add --no-cache \
		curl \
		ca-certificates \
		gzip \
		openssh-client \
		rsync \
		socat \
		qemu-system-x86_64 \
		qemu-system-aarch64 \
		qemu-img \
		ovmf \
		edk2-aarch64 \
		make \
		iproute2 \
		iputils \
		busybox \
		bind-tools \
		wget \
		tcpdump
else
	echo "[devcontainer] unsupported base image: no apt-get or apk found" >&2
	exit 1
fi

# The external-client OpenWrt VM tests create Linux bridges, veth pairs,
# network namespaces and QEMU tap interfaces.  They require a privileged
# devcontainer with NET_ADMIN/NET_RAW and /dev/net/tun access.
if [ ! -e /dev/net/tun ]; then
	sudo mkdir -p /dev/net || true
	sudo mknod /dev/net/tun c 10 200 2>/dev/null || true
	sudo chmod 0666 /dev/net/tun 2>/dev/null || true
fi

if command -v ip >/dev/null 2>&1; then
	probe="dcbr$$"
	probe_log="/tmp/${probe}.log"
	if sudo ip link add name "$probe" type bridge >"$probe_log" 2>&1; then
		sudo ip link del "$probe" >/dev/null 2>&1 || true
		rm -f "$probe_log"
		echo "[devcontainer] NET_ADMIN bridge probe passed"
	else
		cat >&2 <<'MSG'
[devcontainer] warning: NET_ADMIN bridge probe failed.
[devcontainer] OpenWrt external-client VM tests need a rebuilt container with
[devcontainer] privileged networking enabled. The repo devcontainer config
[devcontainer] should include privileged=true, NET_ADMIN/NET_RAW and /dev/net/tun.
MSG
		if [ -s "$probe_log" ]; then
			sed 's/^/[devcontainer]   /' "$probe_log" >&2 || true
		fi
		grep '^Cap' /proc/self/status 2>/dev/null | sed 's/^/[devcontainer] self /' >&2 || true
		sudo sh -c 'grep "^Cap" /proc/self/status' 2>/dev/null | sed 's/^/[devcontainer] sudo /' >&2 || true
		rm -f "$probe_log"
	fi
fi

mkdir -p tests/integration/openwrt_vm/{images,work,scripts,tests}

echo "[devcontainer] OpenWrt VM tools ready"

exit 0
