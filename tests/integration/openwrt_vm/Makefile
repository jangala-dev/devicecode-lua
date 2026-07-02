.PHONY: \
	preflight fetch verify reset run wait provision provision-force ensure-mwan3 \
	stop ssh smoke logs render-default-configs print-default-configs baseline test-baseline test-tc-veth test-lua-uci test-devicecode-uci-manager test-devicecode-uci-manager-async-activation test-devicecode-openwrt-no-blocking-os-io test-devicecode-exec-containment test-openwrt-uart-stty-coreutils test-openwrt-network-provider-apply test-openwrt-network-provider-async-activation test-openwrt-network-provider-fw4-schema test-openwrt-network-provider-snapshot test-openwrt-network-provider-live-snapshot test-openwrt-network-observer-event-ingress test-openwrt-network-provider-vlan-mwan-shaping test-openwrt-network-provider-mwan-live-weights test-openwrt-network-provider-mwan-live-weights-fast test-openwrt-vm-generated-configs-expected test-openwrt-vm-mwan-connected test-openwrt-network-provider-segment-trunk test-devicecode-wired-static-provider test-devicecode-bigbox-phase1-composition test-devicecode-bigbox-phase1-broken-trunk test-openwrt-jan-client-dhcp-dns test-openwrt-int-bridge-client-dhcp-dns test-openwrt-dnsmasq-multi-instance-resilience \
	setup-bridge-client-fabric teardown-bridge-client-fabric \
	network-lab-fetch network-lab-start network-lab-wait network-lab-provision network-lab-sync network-lab-ssh network-lab-stop network-lab-test test-network-lab \
	test openwrt-vm-test clean

preflight:
	./scripts/preflight

fetch:
	./scripts/fetch-image

verify:
	./scripts/verify-image

reset:
	./scripts/reset-disk

run:
	./scripts/run-vm

wait:
	./scripts/wait-ssh

provision:
	./scripts/provision

provision-force:
	OPENWRT_PROVISION_FORCE=1 ./scripts/provision

ensure-mwan3:
	./scripts/ensure-mwan3

stop:
	./scripts/stop-vm

ssh:
	./scripts/ssh

smoke:
	./scripts/wait-ssh
	./scripts/ssh 'uname -a; uci show system | head; ip link; for x in uci ip nft tc; do printf "%s: " "$$x"; command -v "$$x" || echo missing; done'

logs:
	tail -n 200 work/qemu.log

render-default-configs:
	./scripts/wait-ssh
	DEVICECODE_RENDER_PRINT=0 ./scripts/render-default-configs

print-default-configs:
	./scripts/wait-ssh
	DEVICECODE_RENDER_PRINT=1 ./scripts/render-default-configs

baseline: test-baseline

test-baseline:
	./scripts/wait-ssh
	./tests/test_openwrt_baseline.sh

test-tc-veth:
	./scripts/wait-ssh
	./tests/test_tc_veth_baseline.sh

test-lua-uci:
	./scripts/wait-ssh
	./tests/test_lua_uci_baseline.sh

test-devicecode-uci-manager:
	./scripts/wait-ssh
	./tests/test_devicecode_uci_manager.sh

test-devicecode-uci-manager-async-activation:
	./scripts/wait-ssh
	./tests/test_devicecode_uci_manager_async_activation.sh

test-devicecode-openwrt-no-blocking-os-io:
	./tests/test_devicecode_openwrt_no_blocking_os_io.sh

test-openwrt-uart-stty-coreutils:
	./scripts/wait-ssh
	./tests/test_openwrt_uart_stty_coreutils.sh

test-openwrt-network-provider-async-activation:
	./scripts/wait-ssh
	./tests/test_openwrt_network_provider_async_activation.sh

test-openwrt-network-provider-apply:
	./scripts/wait-ssh
	./tests/test_openwrt_network_provider_apply.sh

test-openwrt-network-provider-fw4-schema:
	./scripts/wait-ssh
	./tests/test_openwrt_network_provider_fw4_schema.sh

test-openwrt-network-provider-snapshot:
	./scripts/wait-ssh
	./tests/test_openwrt_network_provider_snapshot.sh

test-openwrt-network-provider-live-snapshot:
	./scripts/wait-ssh
	./tests/test_openwrt_network_provider_live_snapshot.sh

test-openwrt-network-observer-event-ingress:
	./scripts/wait-ssh
	./tests/test_openwrt_network_observer_event_ingress.sh

test-openwrt-network-provider-vlan-mwan-shaping:
	./scripts/wait-ssh
	./tests/test_openwrt_network_provider_vlan_mwan_shaping.sh

test-openwrt-network-provider-mwan-live-weights:
	./scripts/wait-ssh
	./scripts/ensure-mwan3
	./tests/setup_mwan3_three_wan_fixture.sh
	./tests/test_openwrt_network_provider_mwan_live_weights.sh

test-openwrt-network-provider-mwan-live-weights-fast:
	./scripts/wait-ssh
	./tests/test_openwrt_network_provider_mwan_live_weights.sh

test-openwrt-vm-generated-configs-expected:
	./scripts/wait-ssh
	./scripts/ensure-mwan3
	./tests/test_openwrt_vm_generated_configs_expected.sh

test-openwrt-vm-mwan-connected:
	./scripts/wait-ssh
	./scripts/ensure-mwan3
	./tests/test_openwrt_vm_mwan_connected.sh


test-openwrt-network-provider-segment-trunk:
	./scripts/wait-ssh
	./tests/test_openwrt_network_provider_segment_trunk.sh

test-devicecode-wired-static-provider:
	./scripts/wait-ssh
	./tests/test_devicecode_wired_static_provider.sh

test-devicecode-bigbox-phase1-composition:
	./scripts/wait-ssh
	./tests/test_devicecode_bigbox_phase1_composition.sh

test-devicecode-bigbox-phase1-broken-trunk:
	./scripts/wait-ssh
	./tests/test_devicecode_bigbox_phase1_broken_trunk.sh


test-openwrt-jan-client-dhcp-dns:
	./scripts/ensure-jan-client-dhcp-dns-deps
	./tests/test_openwrt_jan_client_dhcp_dns.sh

setup-bridge-client-fabric:
	./scripts/setup-bridge-client-fabric

teardown-bridge-client-fabric:
	./scripts/teardown-bridge-client-fabric

test-openwrt-int-bridge-client-dhcp-dns:
	./scripts/stop-vm || true
	./scripts/setup-bridge-client-fabric
	. ./env.sh; OPENWRT_TAP_IFACES="$$OPENWRT_CLIENT_TAP" ./scripts/run-vm
	./scripts/wait-ssh
	./scripts/provision
	./tests/test_openwrt_int_bridge_client_dhcp_dns.sh


test-openwrt-dnsmasq-multi-instance-resilience:
	./scripts/stop-vm || true
	./scripts/setup-bridge-client-fabric
	. ./env.sh; OPENWRT_TAP_IFACES="$$OPENWRT_CLIENT_TAP" ./scripts/run-vm
	./scripts/wait-ssh
	./scripts/provision
	./tests/test_openwrt_dnsmasq_multi_instance_resilience.sh


network-lab-fetch:
	sh ./scripts/network-lab-fetch-image

network-lab-start:
	sh ./scripts/network-lab-start

network-lab-wait:
	sh ./scripts/network-lab-wait

network-lab-provision:
	sh ./scripts/network-lab-provision

network-lab-sync:
	sh ./scripts/network-lab-sync

network-lab-ssh:
	sh ./scripts/network-lab-ssh

network-lab-stop:
	sh ./scripts/network-lab-stop

network-lab-test test-network-lab:
	sh ./scripts/network-lab-test

test-scp:
	./scripts/wait-ssh
	tmp="$$(mktemp)"; \
	echo "devicecode-openwrt-vm" > "$$tmp"; \
	./scripts/scp-to "$$tmp" /tmp/devicecode-scp-test; \
	./scripts/ssh 'grep -q devicecode-openwrt-vm /tmp/devicecode-scp-test'; \
	./scripts/scp-from /tmp/devicecode-scp-test "$$tmp.out"; \
	grep -q devicecode-openwrt-vm "$$tmp.out"; \
	rm -f "$$tmp" "$$tmp.out"

test: test-baseline test-tc-veth test-lua-uci test-devicecode-uci-manager test-devicecode-uci-manager-async-activation test-devicecode-openwrt-no-blocking-os-io test-devicecode-exec-containment test-openwrt-uart-stty-coreutils test-openwrt-network-provider-apply test-openwrt-network-provider-async-activation test-openwrt-network-provider-fw4-schema test-openwrt-network-provider-snapshot test-openwrt-network-provider-live-snapshot test-openwrt-network-observer-event-ingress test-openwrt-network-provider-vlan-mwan-shaping test-openwrt-network-provider-mwan-live-weights test-openwrt-vm-generated-configs-expected test-openwrt-vm-mwan-connected test-openwrt-network-provider-segment-trunk test-devicecode-wired-static-provider test-devicecode-bigbox-phase1-composition test-devicecode-bigbox-phase1-broken-trunk test-scp

openwrt-vm-test: preflight fetch verify stop reset run wait provision test

clean:
	./scripts/stop-vm
	rm -rf work

test-devicecode-exec-containment:
	@echo "==> devicecode exec containment"
	@$(RUN) tests/test_devicecode_exec_containment.sh

