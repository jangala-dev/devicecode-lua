# Device Service

## Purpose

The Device service is the local, appliance-facing façade over configured components.
It does not open transports, touch the host OS, or implement update policy. Instead it:

1. consumes retained `cfg/device`
2. maintains an in-memory component table
3. supervises one observer child per configured component
4. composes canonical retained device state under `state/device/...`
5. exposes local command topics for aggregate reads, component reads, and component actions

The service is intentionally above raw member transport and raw host capability topics. It watches configured fact and event topics, composes a stable public component view, and exposes only the configured action surface.

## Dependencies

### Retained configuration

| Topic | Purpose |
|---|---|
| `{'cfg','device'}` | Device component configuration. Retained and replayed on startup. |

### Consumed topics and calls

The service has no direct HAL or fabric dependency. It consumes retained fact and event topics, and it dispatches component actions to configured call topics.

Configured inputs are named by each component record:

| Field | Purpose |
|---|---|
| `facts.<name>` | Retained topic watched as a fact source for the component. |
| `events.<name>` | Retained or published event topic watched as an event source for the component. |
| `actions.<name>` | Local action route used by `cmd/device/component/do`. |
| `observe_opts` / `provider_opts` | Observer options passed through to the component observer. |
| `required_facts` | Facts that must have been seen before the component is considered ready. |

### Built-in default component

Even with no retained config, the service includes a built-in `cm5` host component:

```lua
cm5 = {
  class = 'host',
  subtype = 'cm5',
  role = 'primary',
  member = 'local',
  required_facts = { 'software', 'updater' },
  facts = {
    software = { 'cap', 'updater', 'cm5', 'state', 'software' },
    updater  = { 'cap', 'updater', 'cm5', 'state', 'updater' },
    health   = { 'cap', 'updater', 'cm5', 'state', 'health' },
  },
  actions = {
    prepare_update = { 'cap', 'updater', 'cm5', 'rpc', 'prepare' },
    stage_update   = { 'cap', 'updater', 'cm5', 'rpc', 'stage' },
    commit_update  = { 'cap', 'updater', 'cm5', 'rpc', 'commit' },
  },
}
```

Configured components are merged over this default map by component name.

## Configuration

Retained payload on `{'cfg','device'}`:

```lua
{
  schema = 'devicecode.config/device/1',
  components = {
    [<name>] = {
      class = <string|nil>,
      subtype = <string|nil>,
      role = <string|nil>,
      member = <string|nil>,
      member_class = <string|nil>,
      link_class = <string|nil>,
      present = <boolean|nil>,

      observe_opts = <table|nil>,
      provider_opts = <table|nil>,
      required_facts = { <fact_name>, ... } | nil,

      facts = {
        [<fact_name>] = <topic>,
      } | nil,

      events = {
        [<event_name>] = <topic>,
      } | nil,

      actions = {
        [<action_name>] = <topic>
        | {
            kind = 'rpc',
            call_topic = <topic> | nil,
            topic = <topic> | nil,
          }
        | {
            kind = 'fabric_stage',
            artifact_store = <string|nil>,
            link_id = <string>,
            receiver = <topic>,
            timeout_s = <number|nil>,
          },
      } | nil,
    },
  },
}
```

### Normalisation rules

- if `schema` is present and does not match `devicecode.config/device/1`, defaults are used
- configured components are merged by name over the built-in defaults
- each component must define at least one fact or one event after merge
- `facts` and `events` must be tables keyed by non-empty strings with non-empty topic arrays as values
- `actions.<name> = <topic>` normalises to an RPC action route
- RPC actions may be expressed as `{ kind = 'rpc', call_topic = ... }` or `{ kind = 'rpc', topic = ... }`
- `fabric_stage` actions require `link_id` and `receiver`; `artifact_store` defaults to `'main'`
- `provider_opts` is accepted as an alias for `observe_opts`
- `required_facts` is copied through unchanged

## Exposed commands

The service binds four command topics:

| Topic | Purpose |
|---|---|
| `{'cmd','device','get'}` | Return the aggregate `device.self` payload. |
| `{'cmd','device','component','list'}` | Return all public component views. |
| `{'cmd','device','component','get'}` | Return one public component view. |
| `{'cmd','device','component','do'}` | Dispatch a configured component action. |

### `cmd/device/get`

Request payload is ignored.

Response:

```lua
{
  ok = true,
  device = <device.self payload>,
}
```

### `cmd/device/component/list`

Request payload is ignored.

Response:

```lua
{
  ok = true,
  components = { <device.component>, ... },
}
```

The list is sorted by component name.

### `cmd/device/component/get`

Request:

```lua
{
  component = <string>,
}
```

Behaviour:
- returns the current locally composed component view
- does not perform an upstream fetch

Failures:
- `unknown_component`

Successful reply is the component view itself, not an `{ ok = true, ... }` envelope.

### `cmd/device/component/do`

Request:

```lua
{
  component = <string>,
  action = <string>,
  args = <table|nil>,
  timeout = <number|nil>,
}
```

Behaviour:
- resolves `operations[action]`
- for `rpc` actions, calls `call_topic` and returns the callee reply unchanged
- for `fabric_stage` actions:
  - opens `args.artifact_ref` through the configured artifact store capability
  - builds a `cmd/fabric/transfer` request with `op = 'send_blob'`
  - forwards metadata including component, job id, image id, size, checksum and caller metadata
  - returns the transfer reply, defaulting `artifact_retention = 'release'` when absent
  - adds `staged = true` to the returned value

Failures:
- `unknown_component`
- `unknown_action`
- `unsupported_action`
- `missing_artifact_ref`
- `artifact_open_failed`
- any upstream call error

## Retained topics published

| Topic | Payload |
|---|---|
| `{'state','device','self'}` | aggregate `device.self` payload |
| `{'state','device','components'}` | aggregate `device.components` payload |
| `{'state','device','component', <name>}` | canonical `device.component` view |
| `{'state','device','component', <name>, 'software'}` | software facet for that component |
| `{'state','device','component', <name>, 'update'}` | update facet for that component |

Component event observations are also republished as transient publishes under:

| Topic | Payload |
|---|---|
| `{'state','device','component', <name>, 'event', <event_name>}` | last observed event payload for that component/event |

Removed components are explicitly unretained when config changes or the service stops.

## Observation model

Each configured component gets one child observer scope.

The observer runtime is fact-and-event based:

- each configured fact topic is watched and emitted upward as `fact_changed`
- each configured event topic is watched and emitted upward as `event_seen`
- if the observation source closes or faults, the observer emits `source_down`

Observer events are stamped with a generation. The shell ignores stale events from retired observers after config rebuilds.

### Fact handling

On `fact_changed`:
- `raw_facts[fact_name] = payload`
- `fact_state[fact_name].seen = true`
- `fact_state[fact_name].updated_at = now`
- `source_up = true`
- `source_err = nil`

### Event handling

On `event_seen`:
- `raw_events[event_name] = payload`
- `event_state[event_name].seen = true`
- `event_state[event_name].updated_at = now`
- `source_up = true`
- `source_err = nil`
- the payload is published to the component event topic

### Source-down handling

On `source_down`:
- last-seen fact and event caches are retained in memory
- `source_up = false`
- `source_err = <reason>`

## Public projection

### Aggregate summary

`state/device/components` retains:

```lua
{
  kind = 'device.components',
  ts = <monotonic seconds>,
  components = {
    [<name>] = {
      class = <string|nil>,
      subtype = <string|nil>,
      role = <string|nil>,
      member = <string|nil>,
      member_class = <string|nil>,
      link_class = <string|nil>,
      present = <boolean>,
      available = <boolean>,
      ready = <boolean>,
      health = <string>,
      actions = { [<action>] = true, ... },
      software = <table>,
      updater = <table>,
      power = <table>,
      environment = <table>,
      runtime = <table>,
      alerts = <table>,
    },
  },
  counts = {
    total = <integer>,
    available = <integer>,
    degraded = <integer>,
  },
}
```

`state/device/self` retains:

```lua
{
  kind = 'device.self',
  ts = <monotonic seconds>,
  counts = <same counts table>,
  components = <same components table>,
}
```

### Per-component view

`state/device/component/<name>` retains:

```lua
{
  kind = 'device.component',
  ts = <monotonic seconds>,
  component = <name>,
  class = <string|nil>,
  subtype = <string|nil>,
  role = <string|nil>,
  member = <string|nil>,
  member_class = <string|nil>,
  link_class = <string|nil>,
  present = <boolean>,
  available = <boolean>,
  ready = <boolean>,
  health = <string>,
  actions = { [<action>] = true, ... },
  software = <table>,
  updater = <table>,
  power = <table>,
  environment = <table>,
  runtime = <table>,
  alerts = <table>,
  source = {
    kind = 'host' | 'member',
    member = <string|nil>,
    member_class = <string|nil>,
    link_class = <string|nil>,
    role = <string|nil>,
  },
}
```

`available` is true when the source is up and the component has seen at least one fact or event.

`ready` is true when the component is available and all `required_facts` have been seen. For event-only components with no facts, a live event stream is enough to mark the component ready.

`health` is derived as follows:
- explicit component health, when composition provides it, wins
- otherwise `unavailable`/missing source => `'unknown'`
- otherwise updater states `failed` or `unavailable` => `'degraded'`
- otherwise `'ok'`

### Facet payloads

`state/device/component/<name>/software` retains:

```lua
{
  kind = 'device.component.software',
  ts = <monotonic seconds>,
  component = <name>,
  role = <string|nil>,
  member = <string|nil>,
  member_class = <string|nil>,
  link_class = <string|nil>,
  ...software fields...
}
```

`state/device/component/<name>/update` retains:

```lua
{
  kind = 'device.component.update',
  ts = <monotonic seconds>,
  component = <name>,
  available = <boolean>,
  health = <string>,
  actions = { [<action>] = true, ... },
  ...updater fields...
}
```

## Component composition

Two built-in composition paths are present.

### Host components

Components whose subtype is not `mcu` are composed through `component_host`.

Normalised host fields are:
- `software.version`, `build`, `image_id`, `boot_id`, `bootedfw`, `targetfw`, `upgrade_available`, `hw_revision`, `serial`, `board_revision`
- `updater.state`, `raw_state`, `staged`, `artifact_ref`, `artifact_meta`, `expected_image_id`, `last_error`, `updated_at`
- `health` as a simple scalar string when present

### MCU components

Components whose subtype is `mcu` are composed through `component_mcu`.

This path currently normalises and exposes:
- software identity and bundled-image metadata
- updater state, staged image metadata, commit policy, last result and last error
- high-level health and availability
- power battery, charger and charger configuration
- environment temperature and humidity
- runtime memory
- charger alert state
- a `raw` subtree containing the last unnormalised source facts

The exact field set is defined by `services/device/schemas/mcu.lua`.
