#!/usr/bin/env sh
# Host-side test of the firmware script's UCI-to-argv and failure contract.
set -eu
ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT INT TERM
. "$ROOT_DIR/tests/integration/openwrt_vm/fixtures/mdns/mdns-repeater.init"
PROG="$TEST_DIR/repeater"
cat > "$PROG" <<'BIN'
#!/bin/sh
printf '%s\n' 'flags: -w whitelist subnet'
BIN
chmod +x "$PROG"
config_load() { :; }
config_get_bool() { mdns_enabled="$test_enabled"; }
config_get() {
    case "$3" in
        interface) mdns_interfaces="$test_interfaces" ;;
        whitelist) mdns_whitelist="$test_whitelist" ;;
    esac
}
procd_open_instance() { :; }
procd_close_instance() { :; }
procd_set_param() {
    if [ "$1" = command ]; then shift; printf '%s\n' "$@" > "$TEST_DIR/argv"; fi
}
procd_append_param() { shift; printf '%s\n' "$@" >> "$TEST_DIR/argv"; }
test_enabled=1
test_interfaces='generated-adm generated-jan'
test_whitelist='172.28.8.250/32 172.28.8.251/32 172.28.8.252/32 172.28.8.253/32 172.28.8.254/32 172.28.32.0/24'
start_service
{
    printf '%s\n' "$PROG" -f
    for address in $test_whitelist; do printf '%s\n' -w "$address"; done
    printf '%s\n' generated-adm generated-jan
} > "$TEST_DIR/expected"
cmp "$TEST_DIR/argv" "$TEST_DIR/expected"
for invalid in '' '172.28.8.999/32' '172.28.8.250/33' '0.0.0.0/0' '172.28.8.250/32;echo'; do
    test_whitelist="$invalid"
    if start_service; then echo "accepted invalid whitelist: $invalid" >&2; exit 1; fi
done
test_whitelist='172.28.8.250/32'
# An old binary must fail even when the firmware script supports whitelists.
printf '#!/bin/sh\necho "flags: -b blacklist"\n' > "$PROG"
if start_service; then echo 'accepted binary without whitelist support' >&2; exit 1; fi
# Disabled policies need neither a binary nor a whitelist and emit no process.
test_enabled=0
rm "$PROG" "$TEST_DIR/argv"
start_service
[ ! -e "$TEST_DIR/argv" ]
stop() { return 1; }
running() { return 1; }
apply
[ "$(capabilities)" = source-whitelist-v1 ]
echo 'mdns-repeater init contract: ok'
