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

### Host bridge client on internal VLAN 100

For debugging real client behaviour on the internal segment, an optional target
builds a host-side Linux bridge dataplane and starts the VM with a tap-backed
trunk NIC:

```sh
make test-openwrt-int-bridge-client-dhcp-dns
```

This target is intentionally not part of `make test`. It needs host networking
privileges because it creates Linux bridges, veth pairs, network namespaces and
QEMU tap devices. Prefer `make network-lab-test` in CI or from an unprivileged
devcontainer; run this target directly only on a host that grants those
networking permissions. The harness will try to provision common Debian/Ubuntu
packages such as `iproute2`, `udhcpc`, `dnsutils`, `wget` and `tcpdump` when
they are missing.

The fixture uses:

```text
Linux bridge:     brdcint
QEMU tap trunk:   tapdcint, VLAN 100 tagged toward the VM
client namespace: dcintc
client port:      vdcinth as an untagged access port on VLAN 100
OpenWrt trunk:    eth4 by default, derived from OPENWRT_VM_WAN_IFACES + 1
OpenWrt segment:  int / br-int / vl-int / 172.28.100.1/24
```

The test applies a small Devicecode-generated OpenWrt config, obtains a DHCP
lease from a host network namespace over VLAN 100, and checks router reachability,
public-IP reachability, local DNS, public DNS and a public HTTP fetch from that
namespace. On failure it dumps both host bridge/client state and OpenWrt network,
DHCP and dnsmasq diagnostics.

Remove the host-side fixture with:

```sh
make teardown-bridge-client-fabric
```


### Network-lab VM tier

The host-bridge/client targets need privileges that ordinary CI containers
usually should not have: Linux bridges, tap devices, veth pairs and network
namespaces. The `network-lab` tier runs those tests inside a disposable Linux VM
instead, so the top-level devcontainer and fast CI jobs can remain unprivileged.

Default lab workflow:

```sh
make network-lab-test
```

This will:

```text
1. boot a Debian cloud-image VM with QEMU user-mode SSH forwarding
2. provision qemu, iproute2, tcpdump, dnsutils and related tools inside the lab
3. rsync the repository into the lab VM
4. run the privileged OpenWrt dataplane targets inside the lab VM
```

The default lab targets are:

```text
test-openwrt-int-bridge-client-dhcp-dns
test-openwrt-dnsmasq-multi-instance-resilience
```

Run a specific target inside the lab with:

```sh
./scripts/network-lab-test test-openwrt-dnsmasq-multi-instance-resilience
```

Useful lab controls:

```sh
make network-lab-start      # boot the lab VM
make network-lab-wait       # wait for lab SSH
make network-lab-provision  # install lab packages
make network-lab-sync       # rsync the repo into the lab
make network-lab-ssh        # open a shell in the lab VM
make network-lab-stop       # stop the lab VM
```

Important environment knobs:

```text
NETWORK_LAB_SSH_PORT=2242
NETWORK_LAB_MEM=4096M
NETWORK_LAB_CPUS=2
NETWORK_LAB_KVM=auto
NETWORK_LAB_ARCH=auto  # native by default: amd64 on x86_64, arm64 on aarch64
NETWORK_LAB_TEST_TARGETS="test-openwrt-int-bridge-client-dhcp-dns test-openwrt-dnsmasq-multi-instance-resilience"
NETWORK_LAB_OPENWRT_SSH_WAIT_S=600  # nested OpenWrt VM boot budget inside the lab
NETWORK_LAB_OPENWRT_KVM=auto        # passed through to the nested OpenWrt VM lane
NETWORK_LAB_BASE_IMAGE_URL=auto  # Debian genericcloud image matching NETWORK_LAB_ARCH
```

The lab VM is deliberately a separate integration tier. Keep fast unit/provider
tests outside it; use it only for tests where host kernel networking permissions
or platform isolation matter.

The OpenWrt VM runs nested inside this lab VM. If KVM is unavailable either to
the outer lab VM or to the nested OpenWrt VM, the lab remains useful as a
permission boundary but boots much more slowly; the lab therefore uses a larger
nested OpenWrt SSH wait budget than the direct local `openwrt-vm-test` lane.


### Network-lab image/package footprint

The network-lab uses a Debian `genericcloud` image matching the host CPU by
default: `amd64` on x86_64 hosts and `arm64` on AArch64 hosts.  This keeps the
lab VM native and lets the nested OpenWrt VM choose the matching OpenWrt target
through the normal `env.sh` architecture detection.

The lab provisioning intentionally installs packages with `--no-install-recommends`.
Some GUI-looking libraries can still appear because they are hard dependencies of
Debian's QEMU packages, not because the lab image is a desktop image.

The lab scripts also normalise `PATH` to include `/usr/sbin` and `/sbin`.  On
minimal cloud images, tools such as iproute2's `bridge` can be installed but not
visible to the non-login SSH user unless those directories are added explicitly.

### Full service graph with mocked HAL capabilities

`make test-devicecode-full-stack-mock-hal` copies the current source tree into
the OpenWrt VM and runs the real Devicecode services in-process against a bus
with mocked HAL capability providers.  It deliberately excludes the production
`hal` service and replaces the HAL boundary with public capability topics for
filesystem, network, control-store, artifact-store, time and platform.  The test
boots config, device, fabric, gsm, http, metrics, monitor, net, system, time,
ui, update, wifi and wired from their normal source modules.

The fixture asserts that configuration is loaded through the filesystem
capability, the broad service graph reaches retained running/ready state, wired
public state is projected, HTTP capability state is retained, UI runs with raw
HAL topics excluded by default, and network apply requests are serialised by the
mock HAL boundary while config churn is in flight.  This lane is intended to
catch shared-infrastructure regressions in service lifecycle, retained publish,
capability dependency handling, config watch and cancellation semantics under a
real OpenWrt Lua runtime.
