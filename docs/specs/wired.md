# Wired service specification

This document describes the `wired` service as implemented in this tree.

`wired` is the appliance authority for wired physical surfaces. It attaches physical wired surfaces to `net` segments, validates provider capabilities and publishes appliance-level wired state. It does not define segments, VLAN allocation, addressing, DHCP, DNS, routing, firewall, WAN, VPN or shaping policy.

## Current scope

The current implementation is Phase 1 for Big Box wired composition.

It supports:

```text
CM5 Ethernet surface
  protected appliance surface `cm5-eth0`
  represented by a static HAL wired provider

RTL8380M switch uplink surface
  protected appliance surface `switch-uplink-cm5`
  represented by a read-only RTL8380M HTTP HAL wired provider

provider composition
  retained provider capability state under cap/wired-provider/...
  appliance-level surface projection under state/wired/...

protected trunk validation
  required system segments must be carried
  realised user segments may be required through all-realised-user-segments
  provider availability and surface capabilities are checked
```

Phase 1 does not apply switch configuration. The RTL8380M HTTP provider is read-only telemetry. Control operations should report read-only or unsupported rather than pretending to apply.

## Authority split

```text
net
  segment identity, VLAN ids, addressing, DNS/DHCP, firewall, routing,
  WAN, VPN and shaping policy

wired
  appliance wired surfaces, access/trunk attachment, provider capability
  validation, protected trunk invariants, wired topology and violations

device
  appliance component composition and capability promotion

HAL/provider
  static wired facts, RTL8380M HTTP telemetry, future switch APIs,
  OpenWrt switch work or fabric-member calls
```

Rules:

```text
wired consumes state/net/segments.
wired consumes cap/wired-provider/... provider capability state.
wired publishes state/wired/....
wired does not subscribe to raw switch implementation topics.
wired does not define network policy.
```

## Current source layout

```text
src/services/wired/config.lua
src/services/wired/model.lua
src/services/wired/projection.lua
src/services/wired/publisher.lua
src/services/wired/service.lua
src/services/wired/topics.lua

src/services/hal/backends/wired/contract.lua
src/services/hal/backends/wired/provider.lua
src/services/hal/backends/wired/providers/static.lua
src/services/hal/backends/wired/providers/rtl8380m_http.lua
```

`wired` is a house-style service. Its coordinator composes retained state and provider facts. It does not perform OS or switch work inline.

## Configuration shape

`src/services/wired/config.lua` accepts only:

```text
devicecode.config/wired/1
```

and normalises it into:

```text
devicecode.wired.intent/1
```

The current Big Box config defines two protected surfaces:

```text
cm5-eth0
  direct-nic
  internal-trunk
  provider cm5-local-wired / eth0
  required segments adm, int
  user_segments all-realised-user-segments

switch-uplink-cm5
  switch-port
  internal-trunk
  provider switch-main / uplink-cm5
  required segments adm, int
  user_segments all-realised-user-segments
```

Future user-facing switch ports should be added to `cfg/wired` once the fixed RTL8380M port-to-segment layout is known.

## Provider API

A wired provider exposes semantic state, not manufacturer or switch-driver detail.

Provider records contain:

```lua
{
  ok = true,
  provider_id = "switch-main",
  mode = "read_only",
  writable = false,
  status = { state = "available", available = true },
  surfaces = {
    ["uplink-cm5"] = {
      provider_surface_id = "uplink-cm5",
      kind = "switch-port",
      capabilities = { trunk = true, access = false, poe = false },
      link = { state = "up", speed_mbps = 1000 },
      attachment = { mode = "trunk", vlans = { 8, 100, 32, 4 } },
    },
  },
  topology = {},
}
```

Providers should report `access`, `trunk` and `poe` capabilities explicitly. `wired` validates configured surface usage against those capabilities.

No caller above HAL should know manufacturer URL paths, cookies, forms, switch CLI syntax or ASIC register names.

## Protected trunk invariants

`wired` enforces product-level safety around protected internal trunks.

Protected surfaces must:

```text
be enabled
be configured as trunk attachments
name required system segments
have an available provider
have an available provider surface
be backed by a provider surface capable of trunk operation
carry the VLAN ids for all required segments
carry all realised user segments when configured to do so
```

If an invariant is broken, `wired` publishes a violation rather than modifying network policy.

Example violation kinds include:

```text
protected_surface_disabled
protected_surface_not_trunk
protected_provider_missing
protected_provider_unavailable
protected_provider_surface_missing
provider_surface_does_not_support_trunk
missing_required_segment_definition
missing_required_segment_vlan
missing_required_segment_carriage
missing_user_segment_carriage
unknown_segment
```

The Big Box broken-trunk VM test proves that a provider can be physically available while the appliance is still degraded because required VLAN carriage is wrong.

## Retained state

`wired` currently publishes:

```text
state/wired/summary
state/wired/surface/<id>
state/wired/provider/<id>
state/wired/topology
state/wired/violations
```

It consumes:

```text
cfg/wired
state/net/segments
cap/wired-provider/#
```

The service projects stable appliance surface ids. A UI should display `lan-1`, `cm5-eth0` or `switch-uplink-cm5`, not raw provider internals.

## Phase plan

### Phase 1: one-way telemetry

Current state.

```text
RTL8380M manufacturer firmware
read-only HTTP telemetry provider
wired composes and validates appliance surfaces
wired publishes violations and topology
no switch configuration is applied
```

### Phase 2: controlled provider

The same provider family may become writable, but `wired` remains the owner of physical attachment policy and the provider remains the implementation boundary.

Expected operations:

```text
snapshot_op
watch_op
apply_attachments_op
set_poe_op
bounce_op
```

Apply work must be scoped and stale-safe:

```text
configuration or request event
  -> coordinator validates and records desired attachment state
  -> coordinator starts scoped apply work
  -> worker calls provider operation
  -> worker reports wired_apply_done
  -> coordinator stale-checks generation and apply_id
  -> model updates and publishes
```

Even when writable, the provider must not allow the protected CM5-to-switch trunk to be cut.

### Phase 3: switch fabric as a Devicecode member

When the RTL8380M runs OpenWrt and Devicecode, it may publish local `state/wired/...` and `cap/wired/...` through `fabric`.

The CM5-side flow should be:

```text
fabric imports switch member state
  -> device promotes switch-main as an appliance component/capability
  -> wired consumes appliance-level wired-provider capability
  -> ui consumes state/wired/...
```

`wired` should not consume raw member topics directly. `device` owns appliance component and capability promotion.

The preferred final Big Box model is:

```text
CM5 net
  remains the appliance segment and VLAN authority

switch-local wired
  owns switch-local ports and ASIC implementation

CM5 wired
  composes appliance-level surfaces from promoted capabilities
```

## Current tests

Relevant coverage includes:

```text
unit wired config validation
unit static wired provider validation
Big Box phase-one composition
Big Box broken-trunk degradation
OpenWrt VM Big Box composition and broken trunk checks
```

## Current limits

```text
No writable switch application is implemented in Phase 1.
No user-facing switch surfaces are configured in the Big Box sample yet.
PoE policy is modelled as capability information but not yet controlled.
Provider observations are semantic but deliberately minimal for the current phase.
```

## Design north star

`wired` realises the wired fabric of the appliance without claiming network policy.

```text
net owns network meaning.
wired owns physical wired attachment.
HAL/provider code owns implementation.
ui consumes appliance-level state.
```
