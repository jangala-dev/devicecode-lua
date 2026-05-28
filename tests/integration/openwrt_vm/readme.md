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

The VM uses QEMU. A QEMU user-mode NIC is used for SSH and provisioning. By default, three additional QEMU user-mode NICs are attached for deterministic WAN fixtures, normally appearing inside OpenWrt as `eth1`, `eth2` and `eth3`. Optional tap NICs may be added separately for stronger host-bridged dataplane tests.

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
Lua UCI and Devicecode UCI manager behaviour, including async activation ownership
network provider apply/snapshot/observer behaviour, including async OpenWrt activation contract
static scan for fibres-unaware OS/IO calls in NET/OpenWrt HAL paths
VLAN/MWAN/shaping provider behaviour
MWAN3 live-weight updates via iptables-restore --noflush
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

For the default MWAN fixture, three user-mode WAN NICs are attached automatically. Override the count with `OPENWRT_VM_WAN_IFACES` if needed:

```sh
OPENWRT_VM_WAN_IFACES=3 make run
```

For tests requiring host-side dataplane interfaces, provide tap devices explicitly. Each tap becomes an additional virtio NIC after the management and default WAN NICs, which allows MWAN/VLAN experiments with multiple host-bridged WAN or LAN surfaces:

```sh
OPENWRT_TAP_IFACES="tap-dc0 tap-dc1 tap-dc2" make run
```

The management SSH NIC remains separate from any tap dataplane NICs. The MWAN live-weight tests are still self-contained by default, but the tap path is available for fuller end-to-end routing and distribution tests.

## Notes

This lane is intentionally separate from the normal unit suite. It is for tests where container-based execution is not representative, especially OpenWrt HAL work involving UCI, networking reloads, nftables, traffic control, IFB, veth and future shaping or bandwidth-estimation tests.

Keep service logic tests outside this lane where possible. Use this VM lane for behaviour that depends on OpenWrt or kernel networking semantics.
Additional real-VM network tests apply a Devicecode-generated config directly to `/etc/config` while preserving the QEMU management LAN on `eth0` and using the deterministic VM WAN NICs `eth1`, `eth2` and `eth3`. They assert both the generated UCI shape and that mwan3 is active over the VM WAN links.



### Render generated default OpenWrt config files

To see the exact `/etc/config/*` files generated from `src/configs/bigbox-v1-cm-2.json` without modifying the VM's real `/etc/config`, run:

```sh
make render-default-configs
```

The files are copied to:

```text
tests/integration/openwrt_vm/work/generated-default-etc-config/
```

For a stdout dump as well, run:

```sh
make print-default-configs
```

The renderer runs the real OpenWrt provider against a temporary UCI confdir. By default it uses `eth0` as the segment trunk and no GSM uplink facts, so only wired WAN is realised. To render with modem interfaces realised, set:

```sh
DEVICECODE_RENDER_GSM_PRIMARY_IFNAME=wwan0 DEVICECODE_RENDER_GSM_SECONDARY_IFNAME=wwan1 make print-default-configs
```

### Host OVS client on internal VLAN 100

For debugging real client behaviour on the internal segment, an optional target
builds a host-side Open vSwitch dataplane and starts the VM with a tap-backed
trunk NIC:

```sh
make test-openwrt-int-ovs-client-dhcp-dns
```

This target is intentionally not part of `make test`. It needs host privileges
and Open vSwitch support. The harness will try to provision common Debian/Ubuntu
packages such as `openvswitch-switch`, `iproute2`, `udhcpc`, `dnsutils`, `wget`
and `tcpdump` when they are missing.

The fixture uses:

```text
OVS bridge:       ovs-dc-int
QEMU tap trunk:   tap-dc-int, VLAN 100 tagged toward the VM
client namespace: dc-int-client
client port:      veth-dc-int-host as an OVS access port on VLAN 100
OpenWrt trunk:    eth4 by default, derived from OPENWRT_VM_WAN_IFACES + 1
OpenWrt segment:  int / br-int / vl-int / 172.28.100.1/24
```

The test applies a small Devicecode-generated OpenWrt config, obtains a DHCP
lease from a host network namespace over VLAN 100, and checks router reachability,
public-IP reachability, local DNS, public DNS and a public HTTP fetch from that
namespace. On failure it dumps both host OVS/client state and OpenWrt network,
DHCP and dnsmasq diagnostics.

Remove the host-side fixture with:

```sh
make teardown-ovs-client-fabric
```
