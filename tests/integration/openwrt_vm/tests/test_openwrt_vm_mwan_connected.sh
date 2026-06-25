#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
SSH="$VM_DIR/scripts/ssh"

# First generate the real /etc/config/* files without running disruptive
# activation commands inside the Devicecode apply SSH session.  Then activate
# those files with explicit service commands below; a network reload may briefly
# drop the management SSH connection, so each activation phase is bounded and
# followed by wait-ssh.
DEVICECODE_VM_MWAN_CONFIG_ACTIVATE=0 DEVICECODE_VM_MWAN_CONFIG_FORCE=1 "$SCRIPT_DIR/setup_devicecode_vm_mwan_generated_config.sh"

run_activation_step() {
	label="$1"; shift
	echo "[openwrt-vm] activation: $label"
	"$SSH" "$@" || true
	"$VM_DIR/scripts/wait-ssh"
}

run_activation_step 'network reload' "/etc/init.d/network reload >/tmp/devicecode-vm-network-reload.log 2>&1 || { cat /tmp/devicecode-vm-network-reload.log; exit 1; }"
run_activation_step 'firewall restart' "/etc/init.d/firewall restart >/tmp/devicecode-vm-firewall-restart.log 2>&1 || { cat /tmp/devicecode-vm-firewall-restart.log; exit 1; }"
run_activation_step 'mwan3 enable' "/etc/init.d/mwan3 enable >/tmp/devicecode-vm-mwan3-enable.log 2>&1 || true"
run_activation_step 'mwan3 restart' "/etc/init.d/mwan3 restart >/tmp/devicecode-vm-mwan3-restart.log 2>&1 || { cat /tmp/devicecode-vm-mwan3-restart.log; exit 1; }"

"$SSH" 'sh -s' <<'REMOTE'
set -eu
for dev in eth1 eth2 eth3; do
	ip link show "$dev" >/dev/null || { echo "missing $dev" >&2; exit 1; }
done

wait_for() {
	label="$1"; shift
	deadline=$(( $(date +%s) + 45 ))
	while :; do
		if sh -c "$*" >/dev/null 2>&1; then return 0; fi
		if [ "$(date +%s)" -gt "$deadline" ]; then
			echo "timed out waiting for $label" >&2
			sh -c "$*" || true
			exit 1
		fi
		sleep 1
	done
}

wait_for 'wan DHCP address'  "ip -4 addr show dev eth1 | grep -q 'inet 172\.31\.1\.'"
wait_for 'wanb DHCP address' "ip -4 addr show dev eth2 | grep -q 'inet 172\.31\.2\.'"
wait_for 'wanc DHCP address' "ip -4 addr show dev eth3 | grep -q 'inet 172\.31\.3\.'"

ip -4 route show default | tee /tmp/devicecode-vm-default-routes.log
grep -q 'default .* dev eth1 .* metric 11' /tmp/devicecode-vm-default-routes.log
grep -q 'default .* dev eth2 .* metric 12' /tmp/devicecode-vm-default-routes.log
grep -q 'default .* dev eth3 .* metric 13' /tmp/devicecode-vm-default-routes.log

ping -c 1 -W 2 -I eth1 172.31.1.2 >/dev/null
ping -c 1 -W 2 -I eth2 172.31.2.2 >/dev/null
ping -c 1 -W 2 -I eth3 172.31.3.2 >/dev/null

wait_for 'mwan3 balanced policy and https sticky rule' "mwan3 status > /tmp/devicecode-vm-mwan-status.log 2>&1 && grep -q 'balanced:' /tmp/devicecode-vm-mwan-status.log && grep -q 'wan (' /tmp/devicecode-vm-mwan-status.log && grep -q 'wanb (' /tmp/devicecode-vm-mwan-status.log && grep -q 'wanc (' /tmp/devicecode-vm-mwan-status.log && grep -Eq 'S[[:space:]]+https' /tmp/devicecode-vm-mwan-status.log"
wait_for 'mwan3 interfaces online' "mwan3 status > /tmp/devicecode-vm-mwan-status.log 2>&1 && grep -Eq 'interface wan is online|interface wan .* online' /tmp/devicecode-vm-mwan-status.log && grep -Eq 'interface wanb is online|interface wanb .* online' /tmp/devicecode-vm-mwan-status.log && grep -Eq 'interface wanc is online|interface wanc .* online' /tmp/devicecode-vm-mwan-status.log"
cat /tmp/devicecode-vm-mwan-status.log

iptables-save -t mangle >/tmp/devicecode-vm-mangle.rules
grep -q '^:mwan3_policy_balanced ' /tmp/devicecode-vm-mangle.rules
grep -q '^:mwan3_rule_https ' /tmp/devicecode-vm-mangle.rules
grep -q 'mwan3_policy_balanced' /tmp/devicecode-vm-mangle.rules
grep -q -- '--dports 443' /tmp/devicecode-vm-mangle.rules
grep -q '^:mwan3_iface_in_wan ' /tmp/devicecode-vm-mangle.rules
grep -q '^:mwan3_iface_in_wanb ' /tmp/devicecode-vm-mangle.rules
grep -q '^:mwan3_iface_in_wanc ' /tmp/devicecode-vm-mangle.rules
REMOTE

echo 'openwrt VM Devicecode generated config has active MWAN connectivity: ok'
