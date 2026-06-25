# Wired service specification

This document describes the `wired` service as implemented in this tree.

`wired` is the appliance authority for wired physical surfaces. It attaches physical wired surfaces to `net` segments, validates observed source capabilities and publishes appliance-level wired state. It does not define segments, VLAN allocation, addressing, DHCP, DNS, routing, firewall, WAN, VPN or shaping policy.

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

observation composition
  raw wired observations under raw/host/wired/provider/...
  Device physical assembly under state/device/assembly
  appliance-level surface projection under state/wired/...

protected trunk validation
  required system segments must be carried
  realised user segments may be required through all-realised-user-segments
  source availability and observed-surface capabilities are checked
```

Phase 1 does not apply switch configuration. The RTL8380M HTTP provider is read-only observation. Control operations should report read-only or unsupported rather than pretending to apply.

## Authority split

```text
net
  segment identity, VLAN ids, addressing, DNS/DHCP, firewall, routing,
  WAN, VPN and shaping policy

wired
  appliance wired surfaces, access/trunk attachment, observed-source capability
  validation, protected trunk invariants, wired topology and violations

device
  appliance component composition and physical product assembly

HAL/provider
  static wired facts, RTL8380M HTTP observation, future switch APIs,
  OpenWrt switch work or fabric-member calls
```

Rules:

```text
wired consumes state/net/segments.
wired consumes state/device/assembly.
wired consumes raw wired observations.
wired publishes state/wired/....
wired does not expose provider-shaped public capabilities.
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

`wired` is a house-style service. Its coordinator composes retained state and raw wired observations. It does not perform OS or switch work inline.

## Configuration shape

`src/services/wired/config.lua` accepts only:

```text
devicecode.config/wired/1
```

and normalises it into:

```text
devicecode.wired.intent/1
```

The current Big Box config defines protected internal trunks and the fixed external switch surface inventory:

```text
cm5-eth0
  direct-nic
  internal-trunk
  backing surface supplied by state/device/assembly
  required segments adm, int
  user_segments all-realised-user-segments

switch-uplink-cm5
  switch-port
  internal-trunk
  backed by RTL8380M GE8 via state/device/assembly
  required segments adm, int
  user_segments all-realised-user-segments

lan-1 .. lan-7
  external RJ45 surfaces
  backed by RTL8380M GE1 .. GE7 via state/device/assembly
  semantic attachment not yet assigned in cfg/wired

sfp-1 .. sfp-2
  external SFP surfaces
  backed by RTL8380M GE9 .. GE10 via state/device/assembly
  semantic attachment not yet assigned in cfg/wired
```

## Raw wired observations

HAL wired providers publish observation-shaped facts below the public Wired
contract.  For a local source, observations are retained under:

```text
raw/host/wired/provider/<id>/status
raw/host/wired/provider/<id>/state/identity
raw/host/wired/provider/<id>/state/runtime
raw/host/wired/provider/<id>/state/power
raw/host/wired/provider/<id>/state/surfaces
raw/host/wired/provider/<id>/state/topology
```

A surface observation is keyed by the source component's observed surface id, for example
`GE8` on the RTL8380M switch.  Raw observations may carry diagnostic
provenance fields such as `provider_surface_id`, but those names are not part of
the public semantic Wired contract.

`wired` combines these observations with `state/device/assembly`, where the
one true backing vocabulary is `component` plus `observed_surface`.  No caller
above HAL should know manufacturer URL paths, cookies, forms, switch CLI syntax
or ASIC register names.

## Protected trunk invariants

`wired` enforces product-level safety around protected internal trunks.

Protected surfaces must:

```text
be enabled
be configured as trunk attachments
name required system segments
have an available source component
have an available observed source surface
be backed by an observed source surface capable of trunk operation
carry the VLAN ids for all required segments
carry all realised user segments when configured to do so
```

If an invariant is broken, `wired` publishes a violation rather than modifying network policy.

Example violation kinds include:

```text
protected_surface_disabled
protected_surface_not_trunk
protected_source_missing
protected_source_unavailable
protected_observed_surface_missing
observed_surface_does_not_support_trunk
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
state/wired/topology
state/wired/violations
```

It consumes:

```text
cfg/wired
state/net/segments
state/device/assembly
raw/host/wired/provider/#
```

The service projects stable appliance surface ids. A UI should display `lan-1`, `cm5-eth0` or `switch-uplink-cm5`, not raw provider internals.

## Phase plan

### Phase 1: one-way observation

Current state.

```text
RTL8380M manufacturer firmware
read-only HTTP observation provider
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
  -> device describes switch-main in the physical assembly
  -> wired consumes assembly plus switch observations
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
User-facing switch surfaces are present as product inventory; their final access/trunk segment policies remain a later product decision.
PoE policy is modelled as capability information but not yet controlled.
Raw observations are semantic but deliberately minimal for the current phase.
```

## Design north star

`wired` realises the wired fabric of the appliance without claiming network policy.

```text
net owns network meaning.
wired owns physical wired attachment.
HAL/provider code owns implementation-specific observation.
ui consumes appliance-level state.
```


## Provider dependency projection

Raw wired observations are tracked as input facts. Source absence is projected as unavailable/degraded surface state and violations; it is not a service startup failure.
