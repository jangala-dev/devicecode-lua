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
		make
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
		make
else
	echo "[devcontainer] unsupported base image: no apt-get or apk found" >&2
	exit 1
fi

mkdir -p tests/integration/openwrt_vm/{images,work,scripts,tests}

echo "[devcontainer] OpenWrt VM tools ready"

exit 0
