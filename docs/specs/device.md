# Device Service

## Purpose

The Device service is the local, appliance-facing composition service for configured components.

It does **not** open transports, touch the host OS, or implement update policy. Instead it:

1. consumes retained `cfg/device`
2. maintains an in-memory component table
3. supervises one observer child per configured component
4. composes canonical retained device state under `state/device/...`
5. exposes per-component public interfaces under `cap/component/<component>/...`

The service is intentionally above raw member transport and raw host/provider capability topics. It watches configured fact topics, subscribes to configured event topics, composes a stable public component view, and exposes only the configured action surface. This is consistent with the broader Devicecode runtime model, where services sit above HAL and depend on bus-published capabilities and retained state rather than direct OS interaction.

---

## Dependencies

### Retained configuration

* `{'cfg','device'}`
  Retained device component configuration. Replayed on startup.

The service accepts either:

* the config object directly, or
* `{ data = <config object> }`

### Consumed topics and calls

The service has no direct HAL or fabric implementation dependency.

It consumes:

* retained fact topics
* subscribed event topics
* configured action call topics

It may also, for certain action kinds, call stable capability interfaces.

Configured inputs are named by each component record:

* `facts.<name>`
  Retained topic watched with `watch_retained(...)` as a fact source.
* `events.<name>`
  Topic subscribed to with `subscribe(...)` as an event source.
* `actions.<name>`
  Action route normalised into an operation entry.
* `observe_opts` / `provider_opts`
  Observer options passed to the component observer runtime.
* `required_facts`
  Facts that must have been seen before the component is considered ready.

### Additional capability dependencies for `fabric_stage`

If a configured action uses `kind = 'fabric_stage'`, the service additionally depends on:

* raw host artifact-store capability RPC:

  * `raw/host/artifact-store/cap/artifact-store/<id>/rpc/open`
* transfer manager capability RPC:

  * `cap/transfer-manager/main/rpc/send-blob`

That is still consistent with the model of consuming capability interfaces rather than touching the OS directly.

---

## Built-in default component

Even with no retained config, the service includes a built-in `cm5` host component.

```lua
cm5 = {
  class = 'host',
  subtype = 'cm5',
  role = 'primary',
  member = 'local',
  required_facts = { 'software', 'updater' },
  facts = {
    software = { 'raw', 'host', 'updater', 'cap', 'updater', 'cm5', 'state', 'software' },
    updater  = { 'raw', 'host', 'updater', 'cap', 'updater', 'cm5', 'state', 'updater' },
    health   = { 'raw', 'host', 'updater', 'cap', 'updater', 'cm5', 'state', 'health' },
  },
  actions = {
    ['prepare-update'] = { 'raw', 'host', 'updater', 'cap', 'updater', 'cm5', 'rpc', 'prepare' },
    ['stage-update']   = { 'raw', 'host', 'updater', 'cap', 'updater', 'cm5', 'rpc', 'stage' },
    ['commit-update']  = { 'raw', 'host', 'updater', 'cap', 'updater', 'cm5', 'rpc', 'commit' },
  },
}
```

Configured components are merged by name over this default map.

---

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
        [<event_name>] = <topic>
        | {
            subscribe_topic = <topic>,
          },
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

---

## Normalisation rules

* if `schema` is present and does not equal `devicecode.config/device/1`, the service falls back to defaults
* configured components are merged by name over the built-in defaults
* each component must define at least one fact or one event after merge
* `facts` must be a table keyed by non-empty strings with non-empty topic arrays as values
* `events` must be a table keyed by non-empty strings with either:

  * a non-empty topic array, or
  * `{ subscribe_topic = <non-empty topic array> }`
* `actions.<name> = <topic>` normalises to an RPC operation
* RPC actions may be expressed as:

  * `<topic>`
  * `{ kind = 'rpc', call_topic = ... }`
  * `{ kind = 'rpc', topic = ... }`
* `fabric_stage` actions require:

  * `link_id`
  * `receiver`
* `fabric_stage.artifact_store` defaults to `'main'`
* `provider_opts` is accepted as an alias for `observe_opts`
* `required_facts` is copied through unchanged
* public action method names are normalised by replacing underscores with hyphens

Internally, actions are stored under `operations`, not `actions`.

---

## Public interface

## Retained topics published

The service publishes:

* `{'state','device','identity'}`
* `{'state','device','components'}`
* `{'state','device','component', <name>}`
* `{'state','device','component', <name>, 'software'}`
* `{'state','device','component', <name>, 'update'}`
* `{'cap','component', <name>, 'meta'}`
* `{'cap','component', <name>, 'status'}`

Removed components are explicitly unretained when config changes or the service stops.

### Important note

The current implementation does **not** publish:

* `state/device/self`
* `state/device/component/<name>/event/<event_name>`

Observed events are retained only in the service’s in-memory component record and influence composition; they are not republished as separate public event topics.

## Capability metadata

For each component, the service publishes retained metadata at:

* `{'cap','component', <name>, 'meta'}`

Payload:

```lua
{
  owner = <service name>,
  interface = 'devicecode.cap/component/1',
  component = <name>,
  methods = { [<method>] = true, ... },
  canonical_state = { 'state', 'device', 'component', <name> },
}
```

## Capability status

For each component, the service publishes retained status at:

* `{'cap','component', <name>, 'status'}`

Payload:

```lua
{
  state = 'available' | 'unavailable',
  health = <string>,
  ready = <boolean>,
}
```

---

## Exposed RPC methods

The service does **not** currently bind aggregate `cmd/device/...` endpoints.

Instead, for each component it binds:

* `{'cap','component', <name>, 'rpc', 'get-status'}`
* `{'cap','component', <name>, 'rpc', <action_name>}` for every configured action

The current public control surface is therefore **per-component**.

## `cap/component/<name>/rpc/get-status`

Request payload is ignored.

Response is the current canonical component view:

```lua
<device.component payload>
```

Failures:

* `unknown_component`

## `cap/component/<name>/rpc/<action>`

Request payload is treated as the action argument table.

The service does **not** require an outer envelope of the form:

```lua
{
  component = ...,
  action = ...,
  args = ...,
}
```

for these per-component endpoints. Those fields are only relevant to the now-unbound internal legacy-style handler shape.

### RPC action behaviour

For `kind = 'rpc'`:

* calls the configured `call_topic`
* passes the request payload unchanged, defaulting to `{}`
* returns the callee reply unchanged

### `fabric_stage` action behaviour

For `kind = 'fabric_stage'`:

* requires `artifact_ref` in the request payload
* opens the artefact through the configured artifact-store capability
* calls `cap/transfer-manager/main/rpc/send-blob`
* sends:

  * `link_id`
  * `receiver`
  * the opened artifact handle as `source`
  * transfer metadata

The metadata currently includes:

```lua
meta = {
  kind = 'firmware',
  component = <component name>,
  image_id = args.expected_image_id,
  job_id = args.job_id,
  size = <artifact size or nil>,
  checksum = <artifact checksum or nil>,
  metadata = args.metadata or nil,
}
```

Return behaviour:

* returns the transfer reply
* if the reply is not a table, coerces it to `{ ok = true }`
* defaults `artifact_retention = 'release'` when absent
* adds `staged = true`

Failures:

* `unknown_component`
* `unknown_action`
* `unsupported_action`
* `missing_artifact_ref`
* `artifact_open_failed`
* any upstream call failure

---

## Observation model

Each configured component gets one child observer scope.

The observer runtime is fact-and-event based.

### Fact routes

For each configured fact route:

* the service opens a retained watch
* replay is enabled
* received retained/unretained changes are turned into `fact_changed` events

### Event routes

For each configured event route:

* the service opens a subscription
* received messages are turned into `event_seen` events

### Source-down handling

The observer may emit `source_down` when:

* there are no observation topics
* a fact watch closes
* an event subscription closes
* staleness is latched, if `observe_opts.stale_after_s` or `observe_opts.stale_after` is configured

Observer events are stamped with a generation. The shell ignores stale events from retired observers after config rebuilds.

### Fact handling

On `fact_changed`:

* `raw_facts[fact_name] = payload`
* `fact_state[fact_name].seen = true`
* `fact_state[fact_name].updated_at = <observer timestamp if provided>`
* `source_up = true`
* `source_err = nil`

### Event handling

On `event_seen`:

* `raw_events[event_name] = payload`
* `event_state[event_name].seen = true`
* `event_state[event_name].updated_at = <observer timestamp if provided>`
* `event_state[event_name].count += 1`
* `source_up = true`
* `source_err = nil`

### Source-down handling

On `source_down`:

* last-seen fact and event caches are retained in memory
* `source_up = false`
* `source_err = <reason>`

---

## Public projection

## Aggregate summary

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

`state/device/identity` retains:

```lua
{
  kind = 'device.identity',
  ts = <monotonic seconds>,
  counts = <same counts table>,
  components = <same components table>,
}
```

## Per-component view

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

### Availability and readiness

`available` is true when:

* `source_up == true`
* and at least one configured fact or event has been seen

For event-only components:

* if the source is up
* there are no configured facts
* and at least one configured event has been seen

then the component is treated as both available and ready.

`ready` is otherwise:

* `available`
* and all `required_facts` have been seen

### Health derivation

`health` is derived as follows:

1. explicit composed health wins, if present
2. otherwise, if not available: `'unknown'`
3. otherwise, if updater state is `'failed'` or `'unavailable'`: `'degraded'`
4. otherwise: `'ok'`

---

## Facet payloads

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

---

## Component composition

Two built-in composition paths are present.

## Host components

Components whose effective subtype is not `mcu` are composed through `component_host`.

This path currently normalises host-oriented fact trees into public `software`, `updater` and optional `health` material.

For the built-in `cm5` path this is driven by:

* raw host updater `software`
* raw host updater `updater`
* raw host updater `health`

## MCU components

Components whose effective subtype is `mcu` are composed through `component_mcu`.

This path currently normalises and exposes:

* software identity and bundled-image metadata
* updater state, staged image metadata, commit policy, last result and last error
* high-level health
* power battery, charger and charger configuration
* environment temperature and humidity
* runtime memory
* charger alert state

The exact MCU field set is defined by `services/device/schemas/mcu.lua`.
