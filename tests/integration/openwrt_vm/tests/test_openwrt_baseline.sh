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

echo "openwrt baseline: ok"
