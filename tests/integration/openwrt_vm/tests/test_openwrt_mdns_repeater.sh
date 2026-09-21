#!/usr/bin/env sh
set -eu
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(CDPATH= cd -- "$VM_DIR/../../.." && pwd)"
SSH="$VM_DIR/scripts/ssh"
REMOTE=/tmp/devicecode-mdns-test
"$VM_DIR/scripts/wait-ssh"
"$VM_DIR/scripts/ensure-mdns-repeater"
"$SSH" 'opkg install python3-light kmod-veth ip-full'
DEVICECODE_CONFIG_STATE="$REMOTE/backup" "$VM_DIR/scripts/backup-openwrt-config-state"
cleanup() {
    "$SSH" '/etc/init.d/mdns-repeater stop; for segment in adm jan isolated; do ip link del "dcm-$segment" 2>/dev/null || true; done' || true
    DEVICECODE_CONFIG_STATE="$REMOTE/backup" "$VM_DIR/scripts/restore-openwrt-config-state" || true
}
trap cleanup EXIT INT TERM
"$SSH" "mkdir -p '$REMOTE/conf' '$REMOTE/save'"
"$VM_DIR/scripts/scp-to" "$ROOT_DIR/src" "$REMOTE/src"
"$VM_DIR/scripts/scp-to" "$ROOT_DIR/vendor" "$REMOTE/vendor"
"$VM_DIR/scripts/scp-to" "$VM_DIR/fixtures/mdns/render.lua" "$REMOTE/render.lua"
"$VM_DIR/scripts/scp-to" "$VM_DIR/fixtures/mdns/packets.py" "$REMOTE/packets.py"
"$SSH" 'for segment in adm jan isolated; do ip link add "dcm-$segment" type veth peer name "dcmp-$segment"; ip link set "dcm-$segment" up; done'
"$SSH" "cd '$REMOTE' && lua render.lua"
"$SSH" "cp '$REMOTE/conf/network' '$REMOTE/conf/firewall' '$REMOTE/conf/mdns_repeater' /etc/config/; /etc/init.d/network reload"
"$VM_DIR/scripts/wait-ssh"
"$SSH" "/etc/init.d/firewall restart && sh '$REMOTE/activate.sh'"
"$SSH" "python3 '$REMOTE/packets.py'"
# Disabled policy must stop the supervised process, even after a reload.
"$SSH" 'uci set mdns_repeater.main.enabled=0; uci commit mdns_repeater; /etc/init.d/mdns-repeater apply; ! /etc/init.d/mdns-repeater running'
echo 'mdns-repeater routing, source filtering and documented discovery limitations: ok'
