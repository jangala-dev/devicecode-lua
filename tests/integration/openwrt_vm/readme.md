# OpenWrt VM integration tests

This directory provides an opt-in OpenWrt VM test lane for Devicecode integration work.

It is intended for HAL and networking tests that need a real OpenWrt userspace and kernel networking stack, including UCI, `fw4`/nftables, `tc`, IFB and veth devices. It is not part of the normal unit test path.

## Layout

```text
tests/integration/openwrt_vm
  env.sh
  Makefile
  scripts/
  tests/
````

The VM uses QEMU. A QEMU user-mode NIC is used for SSH and provisioning. Optional tap NICs may be added separately for dataplane tests.

## Requirements

On the host:

```text
qemu-system-x86_64 or qemu-system-aarch64
qemu-img
curl
gzip
ssh
scp
sha256sum or shasum
```

On AArch64 hosts, QEMU EFI firmware is also required.

Check the local setup with:

```sh
make preflight
```

## Basic workflow

From this directory:

```sh
make fetch
make reset
make run
make provision
make test
```

Or run the full lane:

```sh
make openwrt-vm-test
```

The default test target currently checks:

```text
OpenWrt baseline tools and state
veth, IFB, HTB, fq_codel and ingress qdisc support
SCP copy to and from the VM
```

## Common commands

```sh
make run          # start the VM
make wait         # wait until SSH is ready
make ssh          # open a root SSH session
make smoke        # show basic VM state
make provision    # install packages needed by the tests
make test         # run current VM tests
make logs         # show recent serial log output
make stop         # stop the VM
make clean        # stop and remove the work disk
```

Force package provisioning to run again:

```sh
OPENWRT_PROVISION_FORCE=1 make provision
```

Use a shorter SSH wait while iterating:

```sh
OPENWRT_SSH_WAIT_S=30 make smoke
```

## Image and disk handling

Images are downloaded into:

```text
images/
```

The downloaded image is verified against OpenWrt `sha256sums` before use.

The writable VM disk is a qcow2 overlay in:

```text
work/
```

Reset it with:

```sh
make reset
```

This discards changes made inside the VM.

## Dataplane testing

The default tests create veth and IFB devices inside the VM. This is enough for many kernel traffic-control tests.

For tests requiring host-side dataplane interfaces, provide tap devices explicitly:

```sh
OPENWRT_TAP_IFACES="tap-dc0 tap-dc1" make run
```

The management SSH NIC remains separate from any tap dataplane NICs.

## Notes

This lane is intentionally separate from the normal unit suite. It is for tests where container-based execution is not representative, especially OpenWrt HAL work involving UCI, networking reloads, nftables, traffic control, IFB, veth and future shaping or bandwidth-estimation tests.

Keep service logic tests outside this lane where possible. Use this VM lane for behaviour that depends on OpenWrt or kernel networking semantics.
