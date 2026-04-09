# Devicecode runtime model: internal proposal 

Describes what we are building, how pieces fit together, and the rules of engagement between services.

## What we are building

Devicecode is a firmware controller for OpenWrt-class devices. It runs multiple “services” inside one process, with each service handling one area (HAL, config, GSM, Wi-Fi, network, time, geo, etc.).

Services communicate via an in-process bus (pub/sub plus a point-to-point command mechanism). Concurrency, cancellation, and cleanup are managed by the fibers runtime.

Intended outcomes:

* clear boundaries between OS/hardware mediation and business logic;  
* predictable shutdown behaviour;  
* host-friendly development and testing (without OpenWrt);  
* baseline security and observability that can evolve over time.

## Key ideas

### 1\) Each service runs in its own scope

A scope is a lifecycle boundary. When a scope is cancelled, everything inside it should stop and clean up (finalisers run).

We run each service in a child scope to get:

* clean shutdown and bounded lifetimes;  
* less cross-service interference;  
* easier unit and integration testing.

### 2\) Each service gets its own bus connection created inside its scope

Every service creates its bus connection within its own scope. This is required so that scope cancellation reliably disconnects that service’s connection and triggers cleanup of:

* subscriptions,  
* endpoints,  
* any Lane B reply endpoints created during calls.

### 3\) HAL is the only component that talks directly to the OS and hardware

HAL mediates all OS/hardware interactions: files, processes, sockets, system tools, sysfs/procfs access, and device discovery.

Non-HAL services must not:

* read/write files directly;  
* call external tools (`ip`, `uci`, `qmicli`, etc.) directly;  
* assume device paths, sysfs layouts, or OpenWrt specifics.

### 4\) Capabilities are how services depend on each other

A capability is “something that provides a feature”, such as:

* modem control,  
* GNSS position source,  
* time source,  
* config store (persistence),  
* higher-level constructs published by domain services (e.g. uplinks).

Capabilities are published under `cap` regardless of which service provides them. HAL provides many hardware-backed capabilities, but other services may publish software-defined capabilities.

## Topics: canonical representation and conventions

### Dense array topics are canonical

All bus topics are **dense arrays** of tokens:

* tokens are strings or numbers (or `bus.literal(v)` when a token must be treated literally even if it equals a wildcard symbol);  
* arrays must use integer keys `1..n` only (dense; no holes).

Documentation may show a “slash form” for readability, but all code should use arrays.

Example:

* documentation: `svc/hal/status`  
* actual topic: `{ 'svc', 'hal', 'status' }`

### Wildcards and “concrete topics”

The bus supports wildcard subscriptions/queries (via trie semantics). However, some operations require *concrete* topics (no wildcards):

* Lane B endpoint binding requires a concrete topic.  
* Lane B `publish_one` and `call` require concrete target and reply topics.  
* Retained publications should use concrete topics.

### Nil payload discipline

Nil payloads are reserved for end-of-stream semantics in underlying mailboxes. Devicecode services should treat `nil` as “no message” / termination and must not publish `payload=nil` as data.

## Startup model (main.lua)

### Responsibilities

`main.lua`:

1. creates the bus;  
2. starts each service in a child scope;  
3. inside each service scope, creates a bus connection;  
4. calls `service:start(conn, opts)`.

Service modules should not directly invoke other service modules for operational interactions; the bus is the runtime boundary.

### Sketch structure (conceptual)

* main scope  
  * HAL scope → `conn_hal` → `hal:start(conn_hal, opts)`  
  * config scope → `conn_cfg` → `config:start(conn_cfg, opts)`  
  * monitor scope → `conn_mon` → `monitor:start(conn_mon, opts)`  
  * gsm scope → `conn_gsm` → `gsm:start(conn_gsm, opts)`  
  * etc.

Ordering may matter for availability, but cancellation correctness derives from: “connection created inside service scope”.

## Bus communication patterns

We use two patterns. They are intentionally different in reliability and backpressure.

### Lane A: pub/sub broadcast (best-effort, bounded)

Use Lane A for:

* discovery (what exists),  
* retained state publication (latest state),  
* event streams (non-retained).

Properties:

* delivery is bounded and best-effort;  
* congestion may cause drops according to subscription mailbox policy;  
* retained state is replayed to new subscribers (best-effort and bounded).

Lane A request helpers may exist as conveniences, but should not be treated as a dependable command interface.

### Lane B: point-to-point commands (explicit admission, bounded)

Use Lane B for:

* commands that must not silently drop,  
* request/response (one caller ↔ one callee),  
* “do X and report whether it worked”.

Properties:

* a service binds an endpoint at a concrete topic;  
* callers use `call`/`` ` `` or `publish_one` to send to that endpoint;  
* endpoint mailboxes use bounded queues with `reject_newest`, so callers receive explicit “full”, “closed”, or “no\_route” outcomes.

## Topic space (consistent top-level groups)

### Service lifecycle

* `{'svc', <name>, 'status'}` (retained)

Suggested payload:

```
{
  state  = 'starting' | 'running' | 'degraded' | 'error' | 'stopped',
  reason = <string|table|nil>,
  ts     = <number>, -- runtime clock or realtime, whichever you standardise on
}
```

### Configuration

* `{'cfg', <service_name>}` (retained): parsed config table for that service.

Config updates and persistence are handled through a capability (see below), not by direct file I/O.

### Devices (typically HAL-owned)

If you use a device tree, keep it separate from `cap`:

* `{'dev', <class>, <id>, 'meta'}` (retained)  
* `{'dev', <class>, <id>, 'state'}` (retained)  
* `{'dev', <class>, <id>, 'event', <name>}` (non-retained)

### Capabilities (HAL or other services)

Capabilities live under `cap` regardless of provider:

* `{'cap', <capability>, <id>, 'meta'}` (retained)  
* `{'cap', <capability>, <id>, 'state'}` (retained)  
* `{'cap', <capability>, <id>, 'event', <name>}` (non-retained)

`meta` should include:

* provider service name,  
* interface version,  
* references to backing devices (if any),  
* any stable identifiers useful to consumers.

### Capability RPC endpoints (Lane B)

For imperative actions, prefer per-method endpoints:

* `{'cap', <capability>, <id>, 'rpc', <method>}` (Lane B endpoint)

This makes allow-lists and future hardening more straightforward than multiplexing everything through a single `rpc` topic.

Example:

* `{'cap', 'config_store', 'primary', 'rpc', 'get'}`  
* `{'cap', 'config_store', 'primary', 'rpc', 'set'}`  
* `{'cap', 'modem', <id>, 'rpc', 'connect'}`  
* `{'cap', 'modem', <id>, 'rpc', 'reset'}`

### Observability

Provide an explicit namespace intended for monitoring/telemetry:

* `{'obs', 'v1', <service>, 'metric', <name>}` (often retained gauges)  
* `{'obs', 'v1', <service>, 'counter', <name>}` (monotonic counters)  
* `{'obs', 'v1', <service>, 'event', <name>}` (non-retained events)

A monitor/telemetry service can subscribe broadly to `{ 'obs', 'v1', '#'}` (or the equivalent token array using your wildcard token), rather than depending on many internal topic trees.

## HAL responsibilities (and boundaries)

HAL should:

* discover hardware and publish what exists (devices/capabilities);  
* implement OS/hardware mediation (files, processes, sockets, system tools);  
* expose imperative operations via `cap/.../rpc/...` endpoints;  
* validate inputs for RPC calls and fail safely.

HAL should not decide policy such as:

* which modem is primary,  
* which APN to use,  
* routing policy,  
* Wi-Fi SSID configuration,  
* time source selection logic.

Those decisions belong in domain services.

## Configuration model (no file handling in config service or any other service)

### Goal

The config service does not know about file paths. It should:

* fetch raw config content via a capability,  
* parse JSON into Lua tables,  
* publish `{ 'cfg', <service> }` retained configs,  
* accept updates (local UI/cloud) and persist them via the same capability.

### Config store capability (HAL-provided initially)

Define a HAL capability for persistence:

* `{'cap', 'config_store', <id>, 'meta'}` retained  
* `{'cap', 'config_store', <id>, 'state'}` retained (optional)  
* RPC endpoints:  
  * `{'cap', 'config_store', <id>, 'rpc', 'get'}`  
  * `{'cap', 'config_store', <id>, 'rpc', 'set'}`

Semantics (example):

* `get(key)` → `{ ok=true, value=<json string> }` or `{ ok=false, err='not_found' }`  
* `set(key, value, opts)` → `{ ok=true }` or `{ ok=false, err=<string> }`

Atomicity and fsync policy belong to HAL.

## Updates and security baseline

### Initial security position

This is one process, so isolation is limited. Baseline controls:

* bounded queues everywhere;  
* explicit command interfaces via Lane B;  
* input validation in RPC endpoints;  
* capability interface versioning in `cap/.../meta`;  
* topic naming discipline so later access controls are feasible.

### Evolution path

Later hardening compatible with this model:

* per-connection allow-lists (publish/subscribe/bind permissions by topic prefix);  
* topic remapping (service-local views);  
* secrets handled via a dedicated capability rather than broadcast in configs.

### Updates

We rely on signed SWUpdate bundles and A/B updates as the root-of-trust mechanism. Devicecode may later integrate with update scheduling via an update-control capability, without becoming part of the trust root.

## Testing strategy (host-friendly)

This architecture is designed for host-based testing:

* services depend on the bus and capabilities, not on real OpenWrt tools;  
* a mocked HAL can run on a laptop and provide predictable capability responses;  
* Lane B endpoints can be faked for unit tests.

Recommended approach (based very much on Ryan’s model):

* unit test service policy by:  
  * publishing retained `cap/.../meta` and `cap/.../state`,  
  * implementing deterministic RPC responses for `cap/.../rpc/...`,  
  * asserting published `svc/.../status`, `cfg/...`, and `obs/v1/...` outputs.  
* test cancellation explicitly:  
  * cancel a service scope and assert subscriptions/endpoints are cleaned up and no further publications occur.  
* integration test by running multiple real services together in one runtime with a mock HAL.

## Phased implementation plan

1. **Bootstrap**  
   * `main.lua` starts services in child scopes with per-scope bus connections  
   * each service publishes `{'svc', name, 'status'}` retained  
2. **HAL foundations**  
   * `cap` inventory (`cap/.../meta`, `cap/.../state`)  
   * initial RPC endpoints for imperative actions  
3. **Config**  
   * HAL provides `cap/config_store/...`  
   * config service publishes `{'cfg', <service>}`  
4. **Domain services**  
   * GSM, time, geo, network, Wi-Fi consume capabilities and apply policy  
   * GSM may publish software-defined `cap/uplink/...`  
5. **Observability**  
   * standardise `obs/v1/...` outputs across services  
   * monitor/telemetry service subscribes to `{'obs','v1',...}` wildcard and exports  
6. **Hardening**  
   * allow-lists and topic remapping hooks  
   * tighten versioning and validation discipline for RPC payloads

## Glossary

* **Scope:** lifecycle boundary for a service; cancellation triggers cleanup.  
* **Bus connection:** per-service handle for publish/subscribe/bind; created inside the service scope.  
* **Device:** physical or OS-visible component (modem, radio, filesystem).  
* **Capability:** interface providing a feature (modem control, time source, config store, uplink).  
* **Retained message:** latest state stored by the bus and replayed to new subscribers (bounded, best-effort).  
* **Lane A:** pub/sub broadcast (bounded, best-effort).  
* **Lane B:** point-to-point command/response with explicit admission and bounded backpressure.

