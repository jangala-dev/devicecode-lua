.PHONY: fetch reset run stop ssh smoke logs

fetch:
	./scripts/fetch-image

reset:
	./scripts/reset-disk

run:
	./scripts/run-vm

stop:
	./scripts/stop-vm

ssh:
	./scripts/ssh

smoke:
	./scripts/wait-ssh
	./scripts/ssh 'uname -a; uci show system | head; ip link; for x in uci ip nft tc; do printf "%s: " "$$x"; command -v "$$x" || echo missing; done'

logs:
	tail -n 200 work/qemu.log

provision:
	./scripts/provision

test-baseline:
	./scripts/wait-ssh
	./tests/test_openwrt_baseline.sh
