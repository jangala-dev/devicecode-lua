# NET service specification

This document describes the `net` service as implemented in this tree.

`net` is the product-level network authority. It owns network intent, apply generations, observation, drift modelling, WAN runtime decisions and retained state publication. It does not own platform implementation detail.

```text
net decides what the network should be.
HAL decides how the host implements it.
```

OpenWrt, UCI, netifd, ubus, dnsmasq, firewall4, MWAN3, `tc`, IFB, u32, HTB, fq_codel, init scripts, sysfs and command execution are HAL backend concerns. `net` talks to HAL through semantic operations only.

## Products

### Big Box

Big Box is a rugged communications station built around:

```text
CM5
  OpenWrt soft router
  main Devicecode Lua runtime
  MT7915 Wi-Fi AP card
  WAN sources including cellular modems

RP2350 MCU
  TinyGo bare-metal controller
  PMU and LTC4015 solar/battery charge-controller integration

RTL8380M switch fabric
  OpenWrt-capable switching fabric
  PoE and wired-port fabric management
```

Given Big Box intended use cases (remote schools, clinics, emergency response and displaced populations), Network behaviour must be resilient, observable, explainable and adaptive.

### Get Box

For Get Box the same `net` contract should apply, even when Wi-Fi, switching and routing are all realised on one OpenWrt target.

## Service boundaries

```text
net
  segments, VLAN identity, addressing, DHCP/DNS policy, firewall,
  routing, WAN, multi-WAN, VPN intent, shaping, diagnostics and state

wifi
  radios, SSIDs, wireless clients, AP policy, channel/power policy,
  wireless inter-links and wireless backhaul presentation

wired
  direct Ethernet surfaces, switch ports, access/trunk attachment,
  PoE capability, link state, provider validation and wired topology

HAL
  all OS-facing and hardware-facing implementation
```

Rules:

```text
If it changes who can talk to whom, it belongs to net.
If it changes how a wireless network is advertised or associated with, it belongs to wifi.
If it changes how a wired physical surface attaches to a segment, it belongs to wired.
If it touches OpenWrt, kernel networking, modem drivers, Wi-Fi drivers or switch ASICs, it belongs behind HAL.
```

`wifi` attaches SSIDs to segment names. `wired` attaches wired surfaces to segment names. Neither duplicates VLAN allocation, DHCP, firewall, routing or WAN policy.

## Implemented configuration shape

`src/services/net/config.lua` accepts only:

```text
devicecode.config/net/1
```

It normalises this into:

```text
devicecode.net.intent/1
```

There are no compatibility migrations inside `net`. Migration must happen before data is written to `cfg/net`.

The current Big Box example is:

```text
src/configs/bigbox-v1-cm-2.json
```

### Authority rules

The current clean config uses this authority split:

```text
segments
  ordinary per-network facts:
  VLAN identity, addressing, segment-local DHCP pool, local DNS behaviour,
  firewall zone attachment and shaping profile reference

top-level dns
  resolver policy, upstreams, cache size, global records and host-file catalogue

top-level dhcp
  defaults, reservations, options and relays

top-level firewall
  defaults, zone definitions, forwarding policies and rules

top-level routing
  static routes and later policy routing

top-level wan
  uplink membership, metrics, base weights, dynamic weighting and health policy

top-level shaping
  profiles and classes; segments refer to profiles

top-level vpn
  overlay/tunnel intent; OpenWrt tunnel application is not implemented yet

top-level diagnostics/runtime
  reflectors, timings and service behaviour
```

In practical terms:

```text
A segment says: I am guest, VLAN 32, 172.28.32.1/24, DHCP enabled,
firewall zone lan_rst, shaping profile restricted_user_per_host.

The shaping section says what restricted_user_per_host means.

The DNS section says which upstreams, cache size, records and host-file sources
exist.

A segment DNS block says which host-file ids apply to that segment.
```

### Content-filter host files

`dns.host_files` is the top-level catalogue for local content-filter host files. A segment references host-file ids in its own `dns.host_files` array.

Example shape:

```json
{
  "dns": {
    "host_files": {
      "base_dir": "/data/devicecode/dns/hosts",
      "addnmount": true,
      "sources": {
        "ads": { "file": "ads.hosts" },
        "adult": { "file": "adult.hosts" }
      }
    }
  },
  "segments": {
    "jan": {
      "dns": { "host_files": ["ads", "adult"] }
    }
  }
}
```

The OpenWrt provider translates these to dnsmasq `addnhosts` and, where requested, `addnmount` entries. The location is configurable through `dns.host_files.base_dir`.

## Current source layout

```text
src/services/net.lua
src/services/net/service.lua
src/services/net/config.lua
src/services/net/schema.lua
src/services/net/model.lua
src/services/net/topics.lua
src/services/net/projection.lua
src/services/net/publisher.lua
src/services/net/events.lua
src/services/net/backpressure.lua
src/services/net/stale.lua
src/services/net/hal_client.lua
src/services/net/generation.lua
src/services/net/apply_runtime.lua
src/services/net/wan_runtime.lua

src/services/net/domain/addressing.lua
src/services/net/domain/dhcp.lua
src/services/net/domain/diagnostics.lua
src/services/net/domain/dns.lua
src/services/net/domain/firewall.lua
src/services/net/domain/interfaces.lua
src/services/net/domain/multiwan.lua
src/services/net/domain/routing.lua
src/services/net/domain/segments.lua
src/services/net/domain/shaping.lua
src/services/net/domain/vpn.lua
```

`src/services/net.lua` is a thin entry point. `service.lua` owns the coordinator loop and service state. Domain modules are pure validation and normalisation code.

## Service discipline

`net` follows the Devicecode `fibers` service discipline.

```text
Ops describe possible waits.
Scopes own lifetimes.
Coordinator branches do not block.
Workers perform blocking HAL, diagnostic or backend-facing work.
Completions carry identity and generation.
Finalisers terminate; they do not wait.
```

The coordinator receives a single next event, reduces it into state changes, starts scoped work where required and publishes immediate retained state. It does not perform HAL work inline.

Implemented scoped work includes:

```text
structural apply
  services.net.apply_runtime

WAN speedtests
  services.net.wan_runtime

live WAN weight application
  services.net.wan_runtime
```

Stale completion rejection is centralised in `services.net.stale` and covers apply, speedtest and live-weight completions.

## HAL network provider

The semantic HAL network provider is under:

```text
src/services/hal/backends/network/provider.lua
src/services/hal/backends/network/contract.lua
src/services/hal/backends/network/providers/fake/init.lua
src/services/hal/backends/network/providers/openwrt/init.lua
```

The OpenWrt provider implements the current platform backend. It translates `devicecode.net.intent/1` into OpenWrt packages and runtime operations. `net` must not require it directly.

Current provider operations include:

```text
validate_op
plan_op
apply_op
snapshot_op
watch_op
probe_link_op
read_counters_op
apply_live_weights_op
apply_shaping_op
speedtest_op
```

## Current OpenWrt apply coverage

The OpenWrt provider applies the current Big Box config domains as follows:

```text
network
  segment trunk VLAN devices on the configured base interface
  segment logical interfaces
  explicit interfaces
  bridge devices where configured
  map-shaped and array-shaped static routes

dhcp / dnsmasq
  per-segment dnsmasq sections where local DNS/DHCP/host files are required
  dns cache size
  upstream DNS servers
  top-level DNS records as dnsmasq address entries
  segment content-filter host files through addnhosts/addnmount
  segment-local DHCP pools
  DHCP reservations
  per-segment DHCP options where configured

firewall
  defaults, including extra default keys present in config
  zones and network membership
  forwarding policies
  rules

mwan3
  WAN interfaces, members, policies and rules
  health basics and mark mask
  live weight application through runtime path

traffic shaping
  segment shaping profile references are compiled into HAL shaper requests
  OpenWrt backend uses the u32/HTB/fq_codel shaper locally

vpn
  intent is normalised and published
  OpenWrt provider currently reports configured tunnels as unsupported
```

Provider apply is fully reconciliatory for the UCI packages it owns. Sections absent from the desired set are removed. UCI application uses the scoped UCI manager transaction path with package snapshots and rollback on partial failure.

## Traffic shaping

The current OpenWrt shaping backend is:

```text
src/services/hal/backends/network/providers/openwrt/tc_u32_shaper.lua
```

It is HAL-local. `net` describes product-level shaping profiles and segment attachments; the backend owns `tc`, IFB, u32, HTB and fq_codel detail.

The model supports per-direction ingress/egress policy, IFB ingress, host-set expansion, per-host HTB/fq_codel deltas, dirty-state recovery and `tc -batch` programming.

## WAN runtime

Speedtests apply to WAN members generally, not only cellular/GSM members. The current service starts scoped speedtest work for eligible WAN members when enabled by config, records identity-bearing completions, and then computes live weights from current speedtest results.

Live weight application is also scoped work and is stale-checked before reduction into the model.

## Observation and drift

Observation is event-led.

```text
events tell us something changed
snapshots tell us what is now true
```

The OpenWrt provider owns raw event ingestion and live snapshots. The current event sources are:

```text
hotplug-style UNIX socket ingress
mwan3.user-style UNIX socket ingress
optional ubus network.interface listener
```

The provider coalesces raw events, takes targeted live snapshots and emits semantic observed events to `net`. `net` reduces those events into observed state and drift.

Current drift is intentionally shallow but structured. It is expected to grow by domain, including firewall, DNS/DHCP, routes, MWAN, shaping and VPN.

## Retained state

`net` currently publishes:

```text
state/net/summary
state/net/apply
state/net/segments
state/net/vlan-policy
state/net/segment/<id>
state/net/interface/<id>
state/net/addressing
state/net/dns
state/net/dhcp
state/net/firewall
state/net/routing
state/net/wan
state/net/wan_runtime
state/net/shaping
state/net/vpn
state/net/diagnostics
state/net/observed
state/net/drift
```

`net` owns `state/net/...` only. It does not publish into `state/wifi/...`, `state/wired/...` or `state/device/...`.

## Current tests

Relevant coverage in this tree includes:

```text
unit net config validation and Big Box clean config shape
unit net service behaviour, stale completion handling and WAN runtime behaviour
unit HAL OpenWrt provider planning/application for DNS, firewall, routes and shaping
unit UCI manager transaction and rollback behaviour
OpenWrt VM baseline
OpenWrt VM UCI manager
OpenWrt VM network provider apply/snapshot/live snapshot
OpenWrt VM observer ingress
OpenWrt VM VLAN/MWAN/shaping
OpenWrt VM live MWAN weights
OpenWrt VM segment trunk
Big Box phase-one composition and broken-trunk checks
```

The VM suite confirms the main OpenWrt-facing seams against a real OpenWrt test target.

## Current limits

Current deliberate limits:

```text
VPN tunnel application is not yet implemented in the OpenWrt provider.
Drift modelling is still early and should be expanded by domain.
The segment trunk implementation is Phase 1 and assumes the configured base interface.
Traffic shaping is powerful but still one backend strategy, not a product-wide optimiser.
```

## Design north star

`net` is the connectivity brain of Big Box and Get Box while remaining platform-agnostic.

```text
net decides connectivity policy.
wifi realises wireless access and wireless transport.
wired realises wired fabric.
HAL performs host/device-specific work.
Devicecode publishes clear, explainable state and decisions.
```
