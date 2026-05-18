# NET service specification

This document is the handover overview for the `net` service.

`net` is the product-level network authority for Devicecode systems. It owns network intent, reconciliation, observation, drift assessment, state publication and network policy decisions. It must not own platform implementation details.

The central rule is:

```text
net decides what the network should be.
HAL decides how the host implements it.
```

`net` normalises `cfg/net` into the product-level intent schema `devicecode.net.intent/1`. OpenWrt, UCI, netifd, ubus, nftables, firewall4, `tc`, MWAN3, SQM, init scripts, sysfs and kernel-facing command execution remain HAL backend concerns.

## Product purpose

Devicecode runs on two main product families.

### Big Box

Big Box is a high-performance rugged router and communications station. The current target architecture includes:

```text
CM5
  OpenWrt soft router
  Devicecode Lua services run here
  MT7915 Wi-Fi AP card
  twin GSM modems

RP2350 MCU
  TinyGo bare-metal controller
  PMU and LTC4015 solar/battery charge controller integration

RTL8380M switch
  OpenWrt switching fabric
  PoE and port fabric management
```

Big Box is intended for remote schools, clinics, emergency response and displaced populations. It may be solar and battery powered. Network behaviour must therefore be resilient, observable, explainable and adaptive.

For Big Box, `net` is expected to support world-class network management capabilities:

- resilient multi-WAN across cellular, wired, satellite or future uplinks;
- responsive failover and recovery;
- event-led observation of network state;
- latency, loss and throughput aware policy decisions;
- traffic shaping, QoS and fairness across constrained links;
- clear segmentation for trusted, guest, emergency and management traffic;
- local operation when cloud connectivity is unavailable;
- cloud and VPN overlay connectivity;
- diagnostics suitable for non-expert operators;
- power-aware network policy in future low-power modes.

### Get Box

Get Box is a 4G/5G router based on MT7981B, designed for digital inclusion.

The same `net` contract should apply to Get Box, even where the physical topology is simpler. The service boundary should not depend on whether Wi-Fi, switching and routing are all on one OpenWrt device or split across several devices.

## Service boundaries

The main services are deliberately separate.

```text
net
  logical networking, segmentation, addressing, routing, firewall,
  WAN policy, VPN, shaping, diagnostics and network state

wifi
  radios, SSIDs, wireless clients, AP policy, channel/power policy,
  wireless inter-links and wireless backhaul presentation

wired
  direct Ethernet interfaces, switch ports, access/trunk mode, VLAN realisation on ports,
  PoE, link state, port counters and switch-chip behaviour

HAL
  all OS-facing and hardware-facing implementation
```

A useful rule is:

```text
If it changes who can talk to whom, it belongs to net.
If it changes how a wireless network is advertised or associated with, it belongs to wifi.
If it changes how a wired physical surface attaches to a segment, it belongs to wired.
If it touches OpenWrt, kernel networking, modem drivers, Wi-Fi drivers or switch ASICs, it belongs behind HAL.
```

`wifi` should attach SSIDs to `net` segment names. It should not duplicate VLAN, DHCP, firewall or WAN policy.

`wired` should attach direct Ethernet interfaces and switch ports to `net` segment names. It should not duplicate routing, DHCP, firewall or WAN policy.

For Big Box, `wired` may consume a curated `cap/wired-provider/...` capability backed initially by a manufacturer HTTP switch-fabric driver, and later by the RTL8380M devicecode member over fabric. For Get Box, `wired` may be local to the MT7981B system. The contract remains the same.

## What `net` owns

`net` owns:

- the segment catalogue and product meaning of segments;
- logical interfaces and interface roles;
- WAN groups and WAN selection policy;
- routing and policy routing intent;
- firewall and isolation intent;
- DHCP and DNS policy at the product level;
- VPN and overlay intent;
- traffic shaping and fairness intent;
- diagnostics policy;
- apply generations and stale-safe completions;
- event-led observation reduction;
- desired versus observed drift assessment;
- `state/net/...` retained state publication.

`net` does not own:

- UCI package names or section formats;
- Linux interface names as implementation detail;
- nftables chains, ruleset syntax or firewall4 internals;
- `tc`, CAKE, HTB, IFB, u32 or qdisc details;
- MWAN3 section names or command output parsing;
- OpenWrt init scripts;
- shell command construction;
- sysfs or procfs paths;
- modem-driver, Wi-Fi-driver or switch-ASIC details.

Those belong in HAL providers.

## Authority and orthogonality

Each top-level section in `cfg/net` has one authority.

```text
segments
  logical networks and their addressing identity

interfaces
  logical attachment points and roles

wan
  uplink groups, health and selection policy

routing
  route selection and policy routing intent

firewall
  reachability, isolation and allow/deny policy

dns
  resolver and naming policy

dhcp
  DHCP pools, reservations and lease policy

shaping
  traffic treatment, fairness, burst, ceil and rate policy

vpn
  overlay and tunnel intent

diagnostics
  probe and test policy

runtime
  net service timing, publication and backpressure policy

metadata
  human, site or fleet metadata only

extensions
  explicitly namespaced experimental data only
```

Sections should reference each other by stable names. They should not restate each other's policy.

Examples:

- an SSID refers to segment `guest`; it does not define VLAN, DHCP or firewall policy;
- a switch port refers to segment `staff`; it does not define routing or DHCP;
- a segment may refer to firewall zone `guest`; the top-level `firewall` section defines what the zone means;
- a segment may refer to shaping profile `guest_fair`; the top-level `shaping` section defines that treatment;
- an interface may have role `wan`; the top-level `wan` section defines membership, weighting and health policy.

## Service discipline

`net` follows the Devicecode `fibers` service discipline.

```text
Ops describe possible waits.
Scopes own lifetimes.
Coordinator branches do not block.
Workers perform blocking HAL, I/O or diagnostic work.
Completions carry identity and generation.
Finalisers terminate; they do not wait.
```

The `net` coordinator should have one normal suspending control point: the next service event.

Coordinator branches may:

- mutate coordinator-owned state;
- start scoped work;
- cancel old generations;
- close admission queues;
- reject or admit requests;
- record pending work;
- ignore stale completions;
- publish immediate retained state through the documented publisher path;
- terminate local handles immediately.

Coordinator branches must not:

- perform HAL calls;
- sleep;
- join child scopes;
- call `join_op()`;
- perform stream I/O;
- execute backend work;
- run OpenWrt commands;
- call graceful `close_op()` operations;
- block on queue capacity.

Blocking work belongs in scoped workers such as apply workers, observer workers, request workers and diagnostics workers.

## Source layout

The expected service layout is:

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
src/services/net/hal_client.lua

src/services/net/generation.lua
src/services/net/apply_runtime.lua
src/services/net/observer_runtime.lua
src/services/net/request_runtime.lua
src/services/net/diagnostics.lua

src/services/net/domain/segments.lua
src/services/net/domain/interfaces.lua
src/services/net/domain/addressing.lua
src/services/net/domain/routing.lua
src/services/net/domain/firewall.lua
src/services/net/domain/dns.lua
src/services/net/domain/dhcp.lua
src/services/net/domain/wan.lua
src/services/net/domain/shaping.lua
src/services/net/domain/vpn.lua
```

Current implementation may not contain every listed file yet. The layout describes the intended direction.

### Entry point

`src/services/net.lua` is a thin service entry point. It loads `services.net.service` and starts the service. It should not contain service logic.

### Coordinator

`service.lua` owns the service scope, config watch, model, publisher, HAL client, active generation, request endpoints and coordinator loop.

### Config boundary

`config.lua` accepts only `devicecode.config/net/1`. Older `net` or `network` shapes are rejected deliberately. Migration belongs before data is written to `cfg/net`.

### Schema and domains

`schema.lua` and `domain/*` are pure. They validate, normalise, compare and project product intent. They perform no Ops and know no platform implementation details.

### Model

`model.lua` is observable state, not a worker. It should provide the standard model surface:

```text
snapshot()
version()
changed_op(seen)
set_snapshot(...)
terminate(reason)
```

The model distinguishes at least:

- config revision;
- normalised intent revision;
- active generation;
- apply status;
- last successful apply;
- last failure;
- HAL capability availability;
- observed state summary;
- drift summary;
- per-segment and per-interface projected state;
- observation and apply statistics.

The model does not perform Ops and does not call HAL.

### Events

`events.lua` builds the service event Op. It should use explicit semantic priority where order affects correctness.

The waking event is only a hint. If priority matters, readiness should be re-checked after waking before selecting the event returned to the coordinator.

### Apply runtime

`apply_runtime.lua` owns scoped apply work. Apply work talks to HAL, stores completion and reports a completion event. The coordinator does not perform HAL apply work inline.

Apply completion events should carry:

```text
kind
apply_id
generation
status
report
result
error
```

### Observer runtime

`observer_runtime.lua` owns service-side observation work where needed. HAL providers are responsible for platform-specific event collection and live snapshots. `net` receives semantic observed events only.

### HAL client

`hal_client.lua` exposes semantic Op-returning methods such as apply, snapshot, watch, probe and counters. It should not expose OpenWrt, UCI or command-execution detail.

## Lifecycle

The intended service lifecycle is:

```text
start
  create model and publisher
  create config watch for cfg/net
  discover required HAL capabilities
  wait for first valid config
  create generation
  start initial apply work
  start observation where capability exists
  enter coordinator loop

config change
  validate and normalise cfg/net
  allocate new generation id
  cancel or supersede old generation
  create new generation
  start apply work
  publish applying state

apply completion
  check generation and apply id
  ignore stale completion
  update model
  publish state
  refresh observation if required

observed event
  reduce semantic observed state into model
  compute drift
  coalesce publication

shutdown/cancellation
  terminate local handles immediately
  cancel generation scopes
  rely on structured scope finalisation to join child work
```

## Event-led observation

Observation is deliberately event-led.

```text
events tell us something changed
snapshots tell us what is now true
```

Raw OpenWrt events are wake-up signals only. They must not become the authoritative product model.

The current OpenWrt observation architecture is:

```text
OpenWrt event source
  -> provider-owned ingress
  -> coalesced subject
  -> targeted live snapshot
  -> semantic HAL observed event
  -> net coordinator
  -> observed state and drift model
  -> retained state publication
```

The provider owns event collection and snapshotting. `net` only sees semantic observed events.

### Event sources

Current event sources are:

```text
hotplug-style UNIX socket ingress
  used by /etc/hotplug.d-style helpers

mwan3.user-style UNIX socket ingress
  used by MWAN3 action hooks

ubus listener
  uses `ubus listen network.interface`
```

The VM-backed event-ingress test has proved the three paths:

```text
hotplug iface event          -> interface:lan
mwan3.user-style event       -> mwan:wan
ubus network.interface event -> interface:loopback
```

### Coalescing

OpenWrt may emit bursts of events for one real change. The provider coalesces by semantic subject, for example:

```text
interface:wan
interface:lan
device:eth0
mwan:wan
firewall
dhcp
network
```

The provider should wait for a short debounce window, then take one targeted snapshot for the subject.

### Live targeted snapshots

The current live snapshot direction is:

```text
network.interface.<name> status
network.device status
route information from netifd interface status
mwan3 status '{}'
```

Important MWAN3 fact: `mwan3` exposes a structured ubus object:

```text
ubus -v list mwan3
  status { section = String, interface = String, policies = String }
```

However, the filters are not reliable in the current environment. The provider should call the full method:

```text
ubus call mwan3 status '{}'
```

and normalise the whole result internally.

The observed MWAN3 shape includes:

```text
interfaces
  per-interface status, score, tracking, enabled, running, up,
  age, uptime, online/offline counters and track_ip results

connected
  IPv4 and IPv6 connected prefixes/addresses

policies
  observed policy membership and percentages
```

This is the correct source for runtime multi-WAN observation. The human-readable `mwan3 status` command should not be parsed unless there is no alternative.

### Semantic observed events

Provider-emitted events should be semantic, for example:

```lua
{
  kind = "mwan_member_changed",
  subject = "mwan:wan",
  source = "ubus-mwan3-status",

  trigger = {
    source = "mwan3.user",
    action = "connected",
    interface = "wan",
    device = "eth1",
  },

  observed = {
    interface = "wan",
    state = "online",
    mwan3_status = "online",
    enabled = true,
    running = true,
    tracking = "active",
    up = true,
    score = 10,
    probes = {
      { ip = "1.0.0.1", status = "up", latency_ms = 0, packetloss_pct = 0 },
    },
  },
}
```

Raw hotplug environment variables should be retained only as diagnostic trigger metadata.

### Startup and safety snapshots

Even event-led observation should start with an initial snapshot. This protects against events that occurred before Devicecode was ready.

A low-frequency watchdog reconciliation snapshot is also acceptable as a safety mechanism, but it should not be the main observation loop.

## Desired, observed and drift

`net` should keep these concepts distinct.

```text
desired
  normalised cfg/net intent

planned
  HAL/backend plan summary, where available

applying
  generation and apply job currently reconciling desired state

observed
  latest semantic state reported by HAL observation

drift
  differences between desired and observed state

published
  curated state exposed to UI, cloud and other services
```

The drift model should grow in stages.

Current simple drift classes include:

```text
missing_interface
unexpected_interface
interface_disabled
```

Expected future drift classes include:

```text
address_mismatch
route_missing
route_unexpected
firewall_zone_mismatch
dhcp_pool_mismatch
dns_policy_mismatch
mwan_member_missing
mwan_member_offline
mwan_weight_mismatch
shaping_policy_missing
vpn_tunnel_down
provider_degraded
```

Drift should be explainable. It should be possible for UI and cloud to show what was desired, what was observed, and why the system considers the network degraded or not converged.

## HAL support for `net`

HAL presents semantic capabilities. Backend providers translate them into platform work.

Initial capabilities:

```text
network-config/main
  validate, plan, apply

network-state/main
  snapshot, watch

network-diagnostics/main
  probe_link, read_counters
```

Future capabilities may be split further when the implementation warrants it:

```text
network-firewall/main
network-routing/main
network-dns-dhcp/main
network-multiwan/main
network-shaping/main
network-vpn/main
```

Do not introduce a separate capability merely because OpenWrt has a separate package. Split when there is a distinct semantic owner, lifecycle, failure mode or test surface.

## HAL source structure

OpenWrt-specific support should live below HAL backend paths, not below `services/net`.

Expected HAL structure:

```text
src/services/hal/managers/network.lua
src/services/hal/drivers/network.lua

src/services/hal/backends/network/contract.lua
src/services/hal/backends/network/provider.lua
src/services/hal/backends/network/providers/fake/init.lua
src/services/hal/backends/network/providers/openwrt/init.lua
src/services/hal/backends/network/providers/openwrt/observer.lua
src/services/hal/backends/network/providers/openwrt/snapshot.lua
src/services/hal/backends/network/providers/openwrt/hotplug_client.lua
src/services/hal/backends/network/providers/openwrt/hotplug_send.lua
```

OpenWrt support may be split further as it matures:

```text
src/services/hal/backends/openwrt/common.lua
src/services/hal/backends/openwrt/uci_manager.lua
src/services/hal/backends/openwrt/uci_singleton_compat.lua
src/services/hal/backends/openwrt/reload_manager.lua

src/services/hal/backends/network/providers/openwrt/intent_to_plan.lua
src/services/hal/backends/network/providers/openwrt/uci_network.lua
src/services/hal/backends/network/providers/openwrt/uci_firewall.lua
src/services/hal/backends/network/providers/openwrt/uci_dhcp.lua
src/services/hal/backends/network/providers/openwrt/uci_mwan3.lua
src/services/hal/backends/network/providers/openwrt/link_state.lua
src/services/hal/backends/network/providers/openwrt/diagnostics.lua
src/services/hal/backends/network/providers/openwrt/traffic_shaping.lua
src/services/hal/backends/network/providers/openwrt/multiwan_runtime.lua
src/services/hal/backends/network/providers/openwrt/vpn.lua
```

## HAL backend responsibilities

The OpenWrt backend may know:

- UCI package names and section formats;
- netifd, firewall4, dnsmasq, odhcpd and procd behaviour;
- ubus object names and method shapes;
- MWAN3 configuration and live state mechanisms;
- SQM, CAKE, HTB, IFB, u32 and other shaping mechanisms;
- WireGuard or other VPN implementation details;
- `ip`, `tc`, `nft`, `ubus` and service reload command shapes;
- sysfs and procfs observation details.

Those details must not leak into `net` intent.

The backend should internally separate:

```text
intent_to_plan
  product-level intent to backend plan

uci_* modules
  backend plan to UCI edits

reload_manager
  semantic reload/restart sequence

observer and snapshot
  event-led live observation and targeted snapshots

link_state
  observed interface/link facts

diagnostics
  probes, counters and tests

traffic_shaping
  shaping policy to SQM/tc implementation

multiwan_runtime
  live WAN weighting and persistence

vpn
  overlay implementation
```

## UCI manager and compatibility singleton

UCI access is OpenWrt HAL infrastructure.

The strict API should be Op-first and scope-owned. The compatibility singleton exists only to preserve older service surfaces, especially for `wifi` during migration.

Rules:

```text
new HAL code uses the scoped UCI manager
new net code never uses UCI directly
new net code never uses the UCI singleton compatibility layer
wifi may temporarily use the compatibility surface
no UCI reactor may be spawned into the root scope
restart and reload execution belongs to HAL/OpenWrt infrastructure
```

Compatibility surface to preserve:

```text
ensure_started
new_session
Session:set
Session:delete
Session:commit
get_value
section_exists
get_sections
```

Preferred strict surface:

```text
new_session
Session:commit_op
submit_op
terminate
```

## Canonical `cfg/net` outline

This is an outline, not a complete schema listing.

```lua
{
  schema = "devicecode.config/net/1",
  version = 1,
  product = "bigbox", -- or "getbox"

  metadata = {
    name = "Big Box site network",
    site_role = "remote_school",
    deployment = "offgrid",
    labels = {},
  },

  segments = {
    mgmt = {
      kind = "management",
      vlan = { id = 10 },
      addressing = { ipv4 = { mode = "static", cidr = "172.28.10.1/24" } },
      dhcp = { enabled = true, pool = "mgmt" },
      dns = { policy = "trusted" },
      firewall = { zone = "mgmt", trust = "infrastructure" },
      shaping = { profile = "management" },
    },

    guest = {
      kind = "guest",
      vlan = { id = 30 },
      addressing = { ipv4 = { mode = "static", cidr = "172.28.30.1/22" } },
      dhcp = { enabled = true, pool = "guest" },
      dns = { policy = "filtered" },
      firewall = { zone = "guest", trust = "untrusted", isolation = "internet_only" },
      shaping = { profile = "guest_fair" },
    },
  },

  interfaces = {
    lan_trunk = {
      kind = "trunk",
      role = "internal",
      segments = { "mgmt", "lan", "guest", "emergency" },
      endpoint = { selector = "switch.uplink" },
    },

    wan_modem_a = {
      kind = "cellular",
      role = "wan",
      endpoint = { selector = "modem.primary" },
      addressing = { ipv4 = { mode = "dhcp", peerdns = false } },
    },
  },

  wan = {
    groups = {
      internet = {
        policy = "weighted_failover",
        members = {
          modem_a = { interface = "wan_modem_a", weight = 50, priority = 1, dynamic_weight = true, cost = "metered" },
          modem_b = { interface = "wan_modem_b", weight = 50, priority = 1, dynamic_weight = true, cost = "metered" },
        },
        health = {
          method = "multi_probe",
          reflectors = { "cloudflare", "quad9", "google" },
          interval_s = 2,
          timeout_s = 2,
          success_threshold = 2,
          failure_threshold = 3,
        },
        runtime_weighting = { enabled = true, min_change_interval_s = 5, persist_quiet_s = 30 },
        last_resort = "reject",
      },
    },
  },

  routing = {},
  firewall = {},
  dns = {},
  dhcp = {},
  shaping = {},
  vpn = {},
  diagnostics = {},

  operating_modes = {
    normal = {},
    low_power = { wan_policy = "prefer_low_power", shaping_profile = "conservative", guest_access = "limited" },
    emergency = { wan_policy = "max_resilience", shaping_profile = "emergency_priority", prioritise_segments = { "emergency", "mgmt" } },
    offline = { wan_policy = "none", local_services = "enabled", guest_access = "local_only" },
  },

  runtime = {
    apply = { debounce_s = 0.5, timeout_s = 30 },
    observe = { debounce_s = 0.15, safety_snapshot_s = 300 },
    publication = { coalesce_s = 0.2, publish_per_interface = true, publish_per_segment = true },
    backpressure = { observer_events = "coalesce_latest", apply_requests = "reject_when_busy" },
  },

  extensions = {},
}
```

## Retained state

Initial retained topics:

```text
state/net/summary
state/net/apply
state/net/observed
state/net/drift
state/net/segment/<id>
state/net/interface/<id>
state/net/addressing
state/net/dns
state/net/dhcp
state/net/firewall
state/net/routing
state/net/wan
state/net/shaping
state/net/vpn
state/net/diagnostics
```

Topic ownership:

```text
state/net/...       owned by net
state/wifi/...      owned by wifi
state/wired/...     owned by wired
state/device/...    owned by device
```

`net` may consume curated state from `device`, `wifi` or `wired` where policy requires it, but it must not publish into their namespaces or consume raw wired-provider facts directly.

## Public request surfaces

Durable network configuration should normally flow through `cfg/net`, not imperative RPC.

Optional request surfaces may include:

```text
network get
network apply-now
network diagnose
network probe
network renew-interface
network bounce-interface
network set-runtime-wan-weight
```

These request surfaces must be scoped request work. They must not cause the coordinator to block on HAL or backend work.

## Backpressure policy

`net` must not let queue capacity silently define service behaviour.

Initial policy:

```text
config events
  must not be dropped

apply completions
  must not be dropped while the service is healthy

observer events
  may be coalesced to latest state by interface, segment or subsystem

diagnostics progress
  may drop progress under pressure, but final result must be kept or the request must fail clearly

request admission
  reject explicitly when busy or overloaded

publication
  coalesce retained updates; retained final state must be accurate
```

Backpressure decisions should be recorded in `services/net/backpressure.lua` and reflected in diagnostics where useful.

## Tests and static checks

Recommended static checks:

```text
net service contains no perform_raw
net service contains no join_op
net service does not require HAL backend modules
net service contains no OpenWrt, UCI, nftables, tc, mwan3 or init-script command strings
coordinator branches do not perform HAL apply work inline
apply work uses scoped_work
completion events carry generation and apply identity
stale completions are ignored
finalisers call terminate, not close_op
legacy config migration is absent from net
```

Recommended HAL checks:

```text
network manager is strict op-only
fake backend satisfies network backend contract
OpenWrt provider is behind HAL boundary
UCI manager is scope-owned
UCI compatibility singleton does not spawn into root scope
restart/reload policy is semantic for new code
```

OpenWrt VM tests should cover:

```text
OpenWrt baseline
Lua UCI baseline
UCI manager
network provider minimal apply
network provider committed snapshot
network provider live snapshot
observer event ingress through hotplug-style socket
observer event ingress through mwan3.user-style socket
observer event ingress through ubus network.interface listener
clean provider termination
```

Current handover status includes VM proof for:

```text
live targeted snapshot: ok
hotplug-style UNIX socket ingress: ok
mwan3.user-style synthetic ingress: ok
ubus network.interface listener: ok
provider termination path: ok
```

## Current state and next priorities

At handover, the important foundations are in place:

```text
net is product-level, not OpenWrt-shaped
host mutation goes through HAL
OpenWrt translation is confined to the provider
UCI is a scoped HAL primitive, not a root singleton
apply work is scoped and identity-bearing
completions are stale-safe
publication is retained and centralised
observation is event-led and provider-owned
OpenWrt VM coverage exercises live snapshot and real ingress paths
```

The next major priorities are:

1. **Harden OpenWrt apply semantics**

   Add provider-owned UCI section markers, safe stale-section deletion, partial-apply reporting and clearer reload sequencing.

2. **Deepen observed state and drift**

   Extend drift beyond basic interface presence to addresses, routes, firewall, DHCP/DNS, MWAN, shaping and VPN.

3. **Build the first adaptive control loop**

   Start with WAN health and live multi-WAN policy. Use event-led observation plus scoped control work. Compare desired WAN policy against observed MWAN3 policy and runtime member state.

4. **Add traffic shaping incrementally**

   Keep `tc`, CAKE, SQM, HTB, IFB and u32 details in HAL. `net` should express shaping intent and consume semantic observed shaping state.

5. **Clarify relationship with `wifi` and `switch`**

   Ensure SSIDs and wired surfaces attach to `net` segment names. Avoid duplicating network policy in those services.

## Design north star

`net` should become the connectivity brain of Big Box and Get Box, while remaining platform-agnostic.

```text
net decides connectivity policy.
wifi realises wireless access and wireless transport.
wired realises wired fabric.
HAL performs host/device-specific work.
Devicecode publishes clear, explainable state and decisions.
```

The aim is not merely to configure interfaces. The aim is to provide responsive, observable and explainable connectivity for difficult environments.
