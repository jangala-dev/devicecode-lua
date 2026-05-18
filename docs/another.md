# Proposal: Big Box internal VLANs, wired surfaces and switch-fabric integration

## 1. Purpose

This proposal defines how Big Box should model and manage its internal Ethernet construction, system VLANs, user VLANs and switch-fabric integration across three implementation phases:

```text
Phase 1
  one-way HTTP telemetry driver to the switch fabric

Phase 2
  two-way HTTP control driver to the switch fabric

Phase 3
  switch fabric runs OpenWrt and its own devicecode instance
```

The aim is to keep the product model stable while the implementation changes underneath it.

The proposal preserves these design goals:

```text
net defines network meaning and VLAN policy

wired defines how wired surfaces attach to network segments

device composes appliance-level component and capability facts

fabric carries member and peer state/capabilities when available

ui consumes appliance-level views and does not care whether resources are local,
integrated, fabric-connected or provided by a peer

HAL/provider code performs all OS, switch, driver and API work
```

---

## 2. Physical context

Big Box contains at least the following relevant components:

```text
CM5
  Runs OpenWrt and the main devicecode instance.
  Has one Ethernet port.
  Acts as the main router/control node.

RTL8380M switch fabric
  Provides additional wired ports for the overall appliance.
  Initially runs manufacturer firmware.
  Later will run OpenWrt and its own devicecode instance.

CM5 Ethernet port <-> fixed RTL8380M uplink port
  This is the protected internal trunk.
```

The CM5 Ethernet port must always carry:

```text
system/internal VLANs
  management
  switch control
  fabric/devicecode internal control, where applicable
  recovery, if separate

public/user VLANs
  lan
  guest
  clinic
  school
  other configured customer/application segments
```

The RTL8380M uplink port connected to the CM5 must also always carry the required system/internal VLANs, and must carry whichever public/user VLANs are required to realise the configured wired surfaces.

This internal trunk is not an ordinary user-configurable port.

---

## 3. Core architectural principle

The key distinction is:

```text
net owns segments and VLAN identity.

wired owns physical carriage and wired attachment.

device owns component and capability composition.

HAL/provider code owns implementation.

fabric transports remote state and capabilities, but does not decide their meaning.
```

In practical terms:

```text
net says:
  "guest exists, uses VLAN 30, is internet-only"

wired says:
  "LAN 2 is an access surface for guest"
  "CM5 eth0 is a protected trunk carrying mgmt, switch-control, fabric, lan, guest"

device says:
  "switch-main is present, healthy, and exposes a wired-provider capability"

HAL/provider says:
  "on this platform that means eth0.30, switch API call X, DSA config Y,
   or OpenWrt UCI state Z"
```

---

## 4. Service responsibilities

### 4.1 `net`

`net` is the network policy and segment authority.

It owns:

```text
segment catalogue
VLAN allocation and reserved VLAN policy
system/internal VLAN identities
addressing
DHCP/DNS policy
firewall and isolation policy
routing
WAN and multi-WAN
VPN
traffic shaping and QoS policy
published network state
```

It does not own:

```text
physical ports
switch ports
PoE
port labels
whether a surface is local or fabric-connected
manufacturer switch APIs
switch ASIC state
SSID presentation
```

### 4.2 `wired`

`wired` is the wired physical attachment authority.

It owns:

```text
wired surfaces
direct Ethernet interfaces
switch ports
access/trunk attachment
surface labels and roles
protected internal trunks
PoE attachment state, where relevant
link state and wired topology
```

It consumes:

```text
net segment catalogue
device-published wired-provider capabilities
cfg/wired
provider observations
```

It publishes:

```text
appliance-level wired surfaces
wired topology
wired provider status
wired attachment state
protected trunk health
```

### 4.3 `device`

`device` is the appliance-level component and capability composer.

It owns:

```text
component inventory
component health
manageability
firmware identity
capability discovery and publication
source abstraction for local, HTTP-driven, fabric-connected or peer-provided resources
```

For the switch fabric, `device` publishes:

```text
component: switch-main
capability: wired-provider
capability: poe-provider, if applicable
capability: update-target, later
```

`wired` should consume the `device` capability view, not raw switch/fabric internals.

### 4.4 `fabric`

`fabric` is the control-plane and state transport between devicecode nodes.

It should:

```text
establish sessions with members and peers
bridge retained state, events and RPC
preserve provenance
clear imported retained state when a session drops
```

It should not:

```text
promote switch ports into appliance ports
decide network topology
decide wired topology
decide component health
```

### 4.5 `ui`

`ui` consumes appliance-level state.

It should be able to display:

```text
LAN 1 -> lan
LAN 2 -> guest
CM5 internal trunk -> protected
switch-main -> healthy/degraded
guest network -> available
```

without knowing whether the port is local, on an RTL8380M, behind HTTP, behind fabric, or on a future peer.

---

## 5. Segment and VLAN model

`net` should define the segment catalogue, including system segments.

Example:

```lua
segments = {
  mgmt = {
    kind = "system",
    protected = true,
    user_editable = false,
    vlan = { reserved = "mgmt", id = 10 },
    purpose = "appliance_management",
  },

  switch_control = {
    kind = "system",
    protected = true,
    user_editable = false,
    vlan = { reserved = "switch_control", id = 11 },
    purpose = "cm5_to_switch_control",
  },

  fabric = {
    kind = "system",
    protected = true,
    user_editable = false,
    vlan = { reserved = "fabric", id = 12 },
    purpose = "internal_devicecode_fabric",
  },

  lan = {
    kind = "user",
    protected = false,
    user_editable = true,
    vlan = { auto = "service" },
    firewall = "trusted",
    dhcp = { enabled = true },
  },

  guest = {
    kind = "user",
    protected = false,
    user_editable = true,
    vlan = { auto = "service" },
    firewall = "internet_only",
    dhcp = { enabled = true },
  },
}
```

`net` should publish:

```text
state/net/segments
state/net/segment/<segment_id>
state/net/vlan-policy
```

A VLAN policy may look like:

```lua
vlan_policy = {
  reserved = {
    mgmt = 10,
    switch_control = 11,
    fabric = 12,
  },

  ranges = {
    system = { from = 10, to = 99 },
    service = { from = 100, to = 199 },
    user = { from = 200, to = 399 },
  },
}
```

---

## 6. Wired surface model

`wired` should model the CM5 Ethernet port and switch-fabric ports as wired surfaces.

### 6.1 Protected infrastructure surfaces

The CM5 Ethernet port:

```lua
{
  surface_id = "cm5-eth0",
  kind = "direct-nic",
  role = "internal-trunk",
  protected = true,

  provider = {
    capability_id = "cm5-local-wired",
    provider_surface_id = "eth0",
  },

  attachment = {
    mode = "trunk",
    required_segments = {
      "mgmt",
      "switch_control",
      "fabric",
    },
    user_segments = "all-realised-user-segments",
  },
}
```

The RTL8380M uplink port facing the CM5:

```lua
{
  surface_id = "switch-uplink-cm5",
  kind = "switch-port",
  role = "internal-trunk",
  protected = true,

  provider = {
    capability_id = "switch-main",
    provider_surface_id = "uplink-cm5",
  },

  attachment = {
    mode = "trunk",
    required_segments = {
      "mgmt",
      "switch_control",
      "fabric",
    },
    user_segments = "all-realised-user-segments",
  },
}
```

### 6.2 User-facing surfaces

Example:

```lua
{
  surface_id = "lan-1",
  kind = "ethernet-port",
  role = "access",
  protected = false,

  provider = {
    capability_id = "switch-main",
    provider_surface_id = "port-1",
  },

  attachment = {
    mode = "access",
    segment = "lan",
  },
}
```

Example trunk port:

```lua
{
  surface_id = "trunk-1",
  kind = "ethernet-port",
  role = "trunk",
  protected = false,

  provider = {
    capability_id = "switch-main",
    provider_surface_id = "port-3",
  },

  attachment = {
    mode = "trunk",
    segments = { "lan", "guest" },
    native_segment = nil,
  },
}
```

---

## 7. Safety invariants

The following invariants should be enforced in code and tests.

### 7.1 Network invariants owned by `net`

```text
reserved VLAN IDs cannot be reused by user segments

protected system segments cannot be disabled

system segment VLAN IDs must remain stable across configuration updates

user VLAN auto-allocation must avoid reserved ranges

segment IDs must be unique and stable

firewall, addressing and routing policy must not allow user segments to break
the system management plane
```

### 7.2 Wired invariants owned by `wired`

```text
protected infrastructure surfaces cannot be disabled

protected infrastructure surfaces must carry all required system segments

user configuration cannot remove system segments from protected trunks

user configuration cannot convert the CM5 internal trunk into an access port

user-facing ports cannot attach directly to protected system segments unless
explicitly allowed by product policy

unknown segment references are rejected or marked degraded according to policy

read-only providers cannot accept writable attachment changes
```

### 7.3 Provider/HAL invariants

```text
providers must report unsupported, read-only and failed operations distinctly

providers must not silently omit required VLANs

providers must report observed state clearly enough for wired to detect drift

provider implementation details must not leak into net, ui or ordinary service
configuration
```

---

## 8. Phase 1: one-way HTTP telemetry driver to the switch fabric

### 8.1 Description

In the initial phase, the RTL8380M switch fabric runs manufacturer firmware. Devicecode on the CM5 can read switch state through an HTTP telemetry driver, but cannot safely or fully control the switch.

The switch fabric is therefore an **observed provider**, not a controlled provider.

### 8.2 Driver location

The HTTP telemetry driver should live below the appliance services, as a provider/driver.

Suggested location:

```text
src/services/hal/backends/wired/providers/rtl8380m_http/
```

or equivalent under the current HAL backend structure.

It should not live in:

```text
services/net
services/wired
services/device
services/ui
services/http
```

The `http` service may be used as transport, but the driver is still a wired-provider driver.

### 8.3 Data flow

```text
rtl8380m_http telemetry driver
  -> provider observations

device
  -> component switch-main
  -> capability wired-provider switch-main, read-only

wired
  -> appliance-level wired surfaces
  -> protected trunk verification
  -> degraded/converged state

ui
  -> displays appliance wired state
```

### 8.4 Publications

The provider or HAL layer may expose raw provider state for diagnostics:

```text
raw/wired/provider/switch-main/status
raw/wired/provider/switch-main/surface/<provider_surface_id>
raw/wired/provider/switch-main/topology
```

`device` publishes appliance-level component/capability state:

```text
state/device/component/switch-main
state/device/capability/wired-provider/switch-main
```

Example capability:

```lua
{
  component_id = "switch-main",
  kind = "wired-provider",

  source = {
    kind = "local-provider",
    driver = "rtl8380m_http",
  },

  mode = "read_only",

  surfaces = {
    {
      provider_surface_id = "uplink-cm5",
      kind = "switch-port",
      capabilities = { trunk = true, access = false },
    },
    {
      provider_surface_id = "port-1",
      kind = "ethernet-port",
      capabilities = { access = true, trunk = true, poe = true },
    },
  },
}
```

`wired` publishes appliance-level state:

```text
state/wired/provider/switch-main
state/wired/surface/cm5-eth0
state/wired/surface/switch-uplink-cm5
state/wired/surface/lan-1
state/wired/surface/lan-2
state/wired/topology
state/wired/violations
```

### 8.5 Behaviour

`wired` should:

```text
compose provider surfaces into product surfaces

verify that the switch uplink carries all required system VLANs

verify that observed fixed VLANs can support configured user surfaces

mark surfaces unavailable or degraded when provider observations disappear

publish violations rather than pretending to apply changes
```

It should not:

```text
attempt to change the switch

pretend read-only observations are authoritative applied state

allow user configuration that assumes unavailable VLANs are present

allow removal of the protected internal trunk
```

### 8.6 Example violation

```lua
{
  kind = "missing_required_segment",
  surface_id = "switch-uplink-cm5",
  provider_surface_id = "uplink-cm5",
  segment = "switch_control",
  vlan = 11,
  severity = "critical",
}
```

### 8.7 Phase 1 tests

```text
HTTP telemetry snapshot produces wired-provider capability through device

wired maps provider port-1 to appliance surface lan-1

wired verifies switch-uplink-cm5 carries required system VLANs

missing management VLAN marks protected trunk degraded

read-only provider rejects control attempts explicitly

loss of HTTP telemetry marks switch-main unavailable

lan-1 remains a stable appliance surface when provider is unavailable

net does not subscribe to raw switch/provider topics

ui can render wired surfaces without provider-specific knowledge
```

---

## 9. Phase 2: two-way HTTP control driver to the switch fabric

### 9.1 Description

In the second phase, the RTL8380M switch still runs manufacturer firmware, but the HTTP driver can apply selected configuration.

The switch fabric becomes a **controlled provider**, but not a devicecode member.

### 9.2 Driver role

The same provider family becomes writable.

It exposes semantic operations such as:

```lua
snapshot_op(req)
watch_op(req)
apply_attachments_op(req)
set_poe_op(req)
bounce_op(req)
```

These operations remain HAL/provider operations. They should not leak manufacturer HTTP calls above the provider boundary.

### 9.3 Data flow

```text
cfg/net
  -> net segment catalogue and VLAN policy

cfg/wired
  -> wired desired surface attachments

device
  -> switch-main wired-provider capability, writable

wired
  -> validates desired attachments against net segments and provider capability
  -> starts scoped apply work
  -> calls provider capability operation
  -> publishes convergence, drift or failure

rtl8380m_http provider
  -> performs manufacturer API calls
  -> reports result and observed state
```

### 9.4 Ownership

`wired` owns the desired port attachment policy.

The provider owns implementation.

`device` owns the capability abstraction.

`net` owns the segment definitions.

### 9.5 Control restrictions

Even when writable, the provider must not allow the protected trunk to be cut.

`wired` should reject requests that would:

```text
remove required system segments from cm5-eth0 or switch-uplink-cm5

convert the switch uplink to an access port

disable the uplink

assign user-facing ports to protected system segments without explicit policy

reuse reserved VLANs for ordinary user segments
```

The provider should also have a final defensive check where possible.

### 9.6 Apply pattern

`wired` should follow the house style:

```text
configuration or request event
  -> coordinator validates and records desired state
  -> coordinator starts scoped apply work
  -> worker calls capability apply_op
  -> worker reports wired_apply_done
  -> coordinator stale-checks generation and apply_id
  -> model updates
  -> publisher emits retained state
```

Completion event:

```lua
{
  kind = "wired_apply_done",
  generation = generation,
  apply_id = apply_id,
  provider_id = "switch-main",

  status = "ok", -- or "failed" / "cancelled"
  report = report,

  result = {
    changed = true,
    observed_rev = "...",
    drift = {},
  },
}
```

### 9.7 Phase 2 tests

```text
writable provider admits valid access-port change

writable provider admits valid trunk-port change

attempt to remove switch_control from protected uplink is rejected before provider call

provider failure reports wired_apply_done failed and model becomes degraded

stale wired_apply_done is ignored

read-only-to-writable transition preserves appliance surface identity

provider applies only semantic attachment state; manufacturer HTTP details do not leak upward

device capability mode change from read_only to writable updates wired behaviour
```

---

## 10. Phase 3: switch fabric runs OpenWrt and its own devicecode

### 10.1 Description

In the final phase, the RTL8380M switch fabric runs OpenWrt and a local devicecode instance. It becomes a fabric-connected member.

It may run:

```text
fabric
device
wired
net, where useful locally
update
hal
possibly http, diagnostics and other services
```

The CM5 and switch fabric now connect their control planes using `fabric`.

### 10.2 New data flow

On the switch node:

```text
switch-local wired
  owns local switch ports and switch ASIC implementation
  publishes local state/wired/...
  exposes local cap/wired/...

switch-local device
  publishes switch component/capability state locally

switch-local fabric
  exports selected state and capabilities to CM5
```

On the CM5:

```text
fabric
  imports switch member state under raw/member/switch-main/...

device
  composes switch-main as an appliance component
  publishes appliance-level wired-provider capability

wired
  consumes appliance-level wired-provider capability
  publishes appliance-level wired surfaces

ui
  consumes appliance-level views
```

### 10.3 Fabric import topics

Imported raw topics may look like:

```text
raw/member/switch-main/state/device/...
raw/member/switch-main/state/wired/...
raw/member/switch-main/cap/wired/...
raw/member/switch-main/cap/update/...
```

`device` is responsible for promotion into appliance-level component/capability facts.

`wired` should not need to consume raw member topics directly.

### 10.4 Appliance capability after promotion

`device` publishes:

```text
state/device/component/switch-main
state/device/capability/wired-provider/switch-main
```

The capability may include:

```lua
{
  component_id = "switch-main",
  kind = "wired-provider",

  source = {
    kind = "fabric-member",
    member_id = "switch-main",
  },

  mode = "writable",

  surfaces = {
    {
      provider_surface_id = "port-1",
      kind = "ethernet-port",
      capabilities = { access = true, trunk = true, poe = true },
    },
    {
      provider_surface_id = "uplink-cm5",
      kind = "switch-port",
      capabilities = { trunk = true, access = false },
    },
  },

  rpc = {
    apply_attachments = {
      topic = { "cap", "device", "capability", "wired-provider", "switch-main", "rpc", "apply-attachments" },
    },
  },
}
```

The exact RPC topic can follow your existing capability conventions. The principle is that `wired` calls an appliance-level capability, not a raw member endpoint.

### 10.5 Local `net` on the switch fabric

Whether the switch node needs a full `net` service depends on what it owns locally.

There are two acceptable patterns.

#### Pattern A: switch-local `wired` only

The switch node runs `wired` and HAL. The CM5 `net` remains the segment authority for the appliance.

```text
CM5 net
  owns segments and VLAN IDs

switch wired
  consumes exported segment catalogue
  applies switch port membership locally
```

This is likely the simplest final Big Box model.

#### Pattern B: switch-local `net` for local infrastructure

The switch node also runs `net` for its own management/control plane, while still accepting appliance segment intent from the CM5.

```text
switch net
  owns only switch-local management networking

CM5 net
  owns appliance segments and user networking
```

If used, this must be carefully scoped to avoid two services both claiming authority over the same user segment catalogue.

For Big Box, Pattern A is the better default.

### 10.6 Phase 3 tests

```text
fabric imports switch-local wired state under raw/member/switch-main/...

device promotes switch-main into appliance component and wired-provider capability

wired consumes device-published capability, not raw/member state

loss of fabric session marks switch-main capability unavailable

appliance surface lan-1 remains stable when switch-main disconnects

wired forwards apply request through appliance-level capability

switch-local wired applies port attachment using its local HAL

CM5 net remains segment authority

switch-local services cannot alter protected CM5-to-switch control segments without policy

update can target switch-main without knowing fabric transport
```

---

## 11. Configuration model

### 11.1 `cfg/net`

`cfg/net` defines network meaning.

Example:

```lua
{
  schema = "devicecode.config/net/1",

  vlan_policy = {
    reserved = {
      mgmt = 10,
      switch_control = 11,
      fabric = 12,
    },
    ranges = {
      service = { from = 100, to = 199 },
      user = { from = 200, to = 399 },
    },
  },

  segments = {
    mgmt = {
      kind = "system",
      protected = true,
      vlan = { reserved = "mgmt" },
      addressing = { ipv4 = { cidr = "192.168.8.1/24" } },
    },

    lan = {
      kind = "user",
      vlan = { auto = "service" },
      addressing = { ipv4 = { cidr = "192.168.10.1/24" } },
      dhcp = { enabled = true },
      firewall = "trusted",
    },

    guest = {
      kind = "user",
      vlan = { auto = "service" },
      addressing = { ipv4 = { cidr = "192.168.30.1/24" } },
      dhcp = { enabled = true },
      firewall = "internet_only",
    },
  },
}
```

### 11.2 `cfg/wired`

`cfg/wired` defines physical wired attachment.

Example:

```lua
{
  schema = "devicecode.config/wired/1",

  surfaces = {
    ["cm5-eth0"] = {
      role = "internal-trunk",
      protected = true,
      provider = {
        capability_id = "cm5-local-wired",
        provider_surface_id = "eth0",
      },
      attachment = {
        mode = "trunk",
        required_segments = {
          "mgmt",
          "switch_control",
          "fabric",
        },
        user_segments = "all-realised-user-segments",
      },
    },

    ["switch-uplink-cm5"] = {
      role = "internal-trunk",
      protected = true,
      provider = {
        capability_id = "switch-main",
        provider_surface_id = "uplink-cm5",
      },
      attachment = {
        mode = "trunk",
        required_segments = {
          "mgmt",
          "switch_control",
          "fabric",
        },
        user_segments = "all-realised-user-segments",
      },
    },

    ["lan-1"] = {
      label = "LAN 1",
      provider = {
        capability_id = "switch-main",
        provider_surface_id = "port-1",
      },
      attachment = {
        mode = "access",
        segment = "lan",
      },
    },

    ["lan-2"] = {
      label = "LAN 2",
      provider = {
        capability_id = "switch-main",
        provider_surface_id = "port-2",
      },
      attachment = {
        mode = "access",
        segment = "guest",
      },
    },
  },
}
```

---

## 12. OpenWrt implementation on the CM5

Although `net` does not own physical surfaces, the CM5 OpenWrt backend still needs to know how to realise segments locally.

That information should be provider/platform configuration, not user network intent.

Example provider configuration:

```lua
platform = {
  segment_trunk = {
    provider_surface = "eth0",
    protected = true,
  },
}
```

Then the OpenWrt provider can implement:

```text
segment guest, VLAN 30
  -> eth0.30
  -> OpenWrt network interface guest
  -> DHCP guest
  -> firewall zone guest
```

`wired` separately states that `cm5-eth0` carries `guest`. This is not a conflict. It is two views of the same intended appliance state:

```text
net/HAL implements the router-side network stack

wired models the physical trunk and validates carriage
```

---

## 13. Failure semantics

### 13.1 Phase 1 failure

If HTTP telemetry fails:

```text
device marks switch-main degraded or unavailable
wired marks switch-provided surfaces unavailable
wired preserves appliance surface identity
net remains segment authority
ui shows degraded wired availability
```

### 13.2 Phase 2 failure

If HTTP control fails:

```text
wired marks apply failed
provider remains available if telemetry still works
surface state may show drift
protected trunk violations remain critical
```

### 13.3 Phase 3 failure

If fabric session to switch-main drops:

```text
fabric clears imported retained raw/member/switch-main state
device marks switch-main unreachable
device withdraws or marks wired-provider capability unavailable
wired marks switch-backed surfaces unavailable
surface IDs remain stable
net does not reinterpret this as a switch-specific failure
```

---

## 14. UI model

The UI should consume appliance-level state:

```text
state/net/segments
state/wired/surface/<surface_id>
state/wired/topology
state/device/component/<component_id>
state/wifi/ssid/<ssid_id>
```

It should not branch on:

```text
manufacturer HTTP driver
OpenWrt switch firmware
fabric member
local direct NIC
DSA
UCI
```

Diagnostic views may show provenance, but ordinary UI views should not require it.

---

## 15. Implementation recommendations

### 15.1 First implementation slice

Implement in this order:

```text
1. Strengthen net segment catalogue and VLAN policy publication.

2. Add minimal wired service:
   - cfg/wired
   - CM5 eth0 protected trunk
   - segment validation
   - state/wired/surface/cm5-eth0
   - state/wired/topology

3. Add device representation of switch-main:
   - component state
   - read-only wired-provider capability

4. Add one-way rtl8380m_http telemetry provider.

5. Have wired compose switch-main provider surfaces into appliance surfaces.

6. Add validation and UI-visible degradation for missing protected VLANs.
```

### 15.2 Second implementation slice

```text
1. Extend rtl8380m_http provider with controlled operations.

2. Add wired apply runtime using scoped_work.

3. Enforce protected trunk invariants before provider calls.

4. Add drift detection between desired cfg/wired and observed provider state.

5. Publish apply status and violations.
```

### 15.3 Final implementation slice

```text
1. Install OpenWrt/devicecode on the RTL8380M.

2. Run fabric, device, wired, hal and update on the switch node.

3. Import switch state/capabilities over fabric.

4. Promote imported member facts through device.

5. Keep wired consuming appliance-level wired-provider capability.

6. Retire the manufacturer HTTP driver.
```

---

## 16. Architectural decision

The proposed decision is:

```text
Big Box will model the CM5-to-switch link as a protected internal trunk.

net owns the system and user segment catalogue, including VLAN identity and
reserved VLAN policy.

wired owns physical wired surfaces and validates that protected surfaces carry
the required system segments.

device composes the RTL8380M switch fabric into an appliance-level component and
wired-provider capability.

In Phase 1, a one-way HTTP telemetry provider feeds switch observations into
device and wired.

In Phase 2, a two-way HTTP provider allows wired to apply controlled port and
trunk configuration through a provider capability.

In Phase 3, the switch fabric runs OpenWrt and devicecode; fabric imports its
state and capabilities, device promotes them into appliance-level capabilities,
and wired continues to present stable appliance wired surfaces.

The UI and net service do not depend on whether the switch is read-only,
HTTP-controlled, or running its own devicecode.
```

This gives Big Box a stable appliance model from the first prototype through to the final multi-node devicecode architecture.
