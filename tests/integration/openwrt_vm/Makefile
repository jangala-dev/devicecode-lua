.PHONY: \
	preflight fetch verify reset run wait provision provision-force \
	stop ssh smoke logs baseline test-baseline test-tc-veth test \
	openwrt-vm-test clean

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

stop:
	./scripts/stop-vm

ssh:
	./scripts/ssh

smoke:
	./scripts/wait-ssh
	./scripts/ssh 'uname -a; uci show system | head; ip link; for x in uci ip nft tc; do printf "%s: " "$$x"; command -v "$$x" || echo missing; done'

logs:
	tail -n 200 work/qemu.log

baseline: test-baseline

test-baseline:
	./scripts/wait-ssh
	./tests/test_openwrt_baseline.sh

test-tc-veth:
	./scripts/wait-ssh
	./tests/test_tc_veth_baseline.sh

test-scp:
	./scripts/wait-ssh
	tmp="$$(mktemp)"; \
	echo "devicecode-openwrt-vm" > "$$tmp"; \
	./scripts/scp-to "$$tmp" /tmp/devicecode-scp-test; \
	./scripts/ssh 'grep -q devicecode-openwrt-vm /tmp/devicecode-scp-test'; \
	./scripts/scp-from /tmp/devicecode-scp-test "$$tmp.out"; \
	grep -q devicecode-openwrt-vm "$$tmp.out"; \
	rm -f "$$tmp" "$$tmp.out"

test: test-baseline test-tc-veth test-scp

openwrt-vm-test: preflight fetch verify reset run wait provision test

clean:
	./scripts/stop-vm
	rm -rf work
