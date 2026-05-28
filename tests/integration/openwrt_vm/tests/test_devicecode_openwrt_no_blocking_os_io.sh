#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(CDPATH= cd -- "$VM_DIR/../../.." && pwd)"

cd "$ROOT_DIR"

PATHS="
src/services/hal/backends/openwrt
src/services/hal/backends/network/providers/openwrt
src/services/net
"

matches=""
for path in $PATHS; do
  if [ -d "$path" ]; then
    found="$(grep -RInE '\b(os\.execute|io\.open|os\.remove|io\.popen|popen)\s*\(' "$path" 2>/dev/null || true)"
    if [ -n "$found" ]; then
      matches="${matches}${found}
"
    fi
  fi
done

if [ -n "$matches" ]; then
  printf '%s\n' 'fibres-unaware OS/IO calls found in OpenWrt NET/HAL paths:' >&2
  printf '%s\n' "$matches" >&2
  exit 1
fi

printf '%s\n' 'devicecode OpenWrt NET/HAL no blocking OS/IO scan: ok'
