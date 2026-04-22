# Device Service

## Purpose

The Device service is the appliance-facing façade over configured components.
It does not implement drivers, transport, or device policy. Instead it:

1. consumes retained `cfg/device`
2. maintains an in-memory component table
3. supervises one observer child per configured component
4. projects canonical retained device state under `state/device/...`
5. exposes local command topics for aggregate reads, component reads, and component actions

The service is intentionally thin. It consumes whatever a component definition names and republishes a stable local shape for the rest of DeviceCode.

## Dependencies

### Retained configuration

| Topic | Purpose |
|---|---|
| `{'cfg','device'}` | Device component configuration. Retained and replayed on startup. |

### Consumed topics and calls

The service has no direct HAL dependency. It consumes whatever each component definition names.

| Config field | Purpose |
|---|---|
| `provider` | Observer/provider kind. Defaults to `status_watch`. |
| `channels.status.watch_topic` | Optional watch topic for ongoing status updates. |
| `channels.status.get_topic` | Optional call topic for initial fetch and explicit `get` requests. |
| `operations.*.call_topic` | Call topics used by `cmd/device/component/do`. |

### Built-in default component

Even with no retained config, the service includes a built-in `cm5` host component:

```lua
cm5 = {
  class = 'host',
  subtype = 'cm5',
  role = 'primary',
  member = 'local',
  channels = {
    status = {
      watch_topic = { 'cap', 'updater', 'cm5', 'state', 'status' },
      get_topic = { 'cap', 'updater', 'cm5', 'rpc', 'status' },
    },
  },
  operations = {
    prepare_update = { call_topic = { 'cap', 'updater', 'cm5', 'rpc', 'prepare' } },
    stage_update   = { call_topic = { 'cap', 'updater', 'cm5', 'rpc', 'stage' } },
    commit_update  = { call_topic = { 'cap', 'updater', 'cm5', 'rpc', 'commit' } },
  },
}
```

Configured components merge over this default map by component name.

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

      provider = <string|nil>,
      provider_opts = <table|nil>,

      status_topic = <topic|nil>,
      get_topic = <topic|nil>,

      channels = {
        status = {
          watch_topic = <topic|nil>,
          get_topic = <topic|nil>,
        },
      } | nil,

      actions = {
        [<action_name>] = <topic>,
      } | nil,

      operations = {
        [<action_name>] = {
          call_topic = <topic>,
        },
      } | nil,
    },
  },
}
```

### Normalisation rules

- if `schema` is present and does not match `devicecode.config/device/1`, defaults are used
- configured components are merged by name over the built-in defaults
- legacy convenience fields are accepted:
  - `status_topic` maps to `channels.status.watch_topic`
  - `get_topic` maps to `channels.status.get_topic`
  - `actions.<name> = <topic>` maps to `operations.<name>.call_topic`
- if `provider` is not supplied, it defaults to `status_watch`
- operations are normalised to records of the form:
  - `name`
  - `call_topic`

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
  args = <table|nil>,
  timeout = <number|nil>,
}
```

Behaviour:

- if cached raw status is already present, reply immediately with the projected component view
- otherwise, if `channels.status.get_topic` is configured, fetch in a helper fibre, update local state, signal publication, and reply with the projected component view
- otherwise fail with `no_status_available`

Failures:

- `unknown_component`
- `no_status_available`
- any upstream fetch error

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

- resolve `operations[action].call_topic`
- call that topic in a helper fibre
- return the callee reply unchanged

Failures:

- `unknown_component`
- `missing_action`
- `unsupported_action`
- any upstream call error

## Retained topics published

| Topic | Payload |
|---|---|
| `{'state','device','self'}` | aggregate `device.self` payload |
| `{'state','device','components'}` | aggregate `device.components` payload |
| `{'state','device','component', <name>}` | canonical `device.component` view |
| `{'state','device','component', <name>, 'software'}` | software facet for that component |
| `{'state','device','component', <name>, 'update'}` | update facet for that component |

Removed components are explicitly unretained when config changes or the service stops.

## Observation model

Each configured component gets one child observer scope.

### Provider model

Providers are selected by `rec.provider`.
Current built-in provider:

- `status_watch`

`status_watch` behaviour:

1. if `channels.status.get_topic` exists, issue one initial call with `{}` and timeout `0.5s`
2. if that call succeeds, emit `raw_changed`
3. if `channels.status.watch_topic` exists, subscribe to it with bounded buffering
4. for each received message:
   - use `msg.payload` if present
   - otherwise use `msg`
   - emit `raw_changed`
5. if the watch closes or the provider faults, emit `source_down`

Shell-side effects:

- `raw_changed`:
  - `raw_status = payload`
  - `source_up = true`
  - `source_err = nil`
- `source_down`:
  - `raw_status = { state = 'unavailable', err = <reason> }`
  - `source_up = false`
  - `source_err = <reason>`

Observer events are stamped with a generation. The shell ignores stale events from retired observers.

## Public component projection

Primary retained payload shape:

```lua
{
  kind = 'device.component',
  ts = <monotonic seconds>,
  component = <name>,
  class = <string>,
  subtype = <string>,
  role = <string>,
  member = <string>,
  member_class = <string>,
  link_class = <string|nil>,
  present = <boolean>,
  available = <boolean>,
  ready = <boolean>,
  health = 'ok' | 'degraded' | 'unknown' | <string>,
  actions = { [<action_name>] = true, ... },
  capabilities = { [<capability>] = true, ... },
  software = {
    version = <string|nil>,
    build = <string|nil>,
    image_id = <string|nil>,
    boot_id = <string|nil>,
  },
  updater = {
    state = <string|nil>,
    last_error = <string|nil>,
    ...
  },
  source = {
    kind = 'host' | 'member' | <string>,
    member = <string>,
    member_class = <string>,
    link_class = <string|nil>,
    role = <string>,
    status = {
      watch_topic = <topic|nil>,
      get_topic = <topic|nil>,
    },
    ...
  },
  raw = <source payload clone|nil>,
}
```

### Projection rules

The service supports two input shapes.

#### A. Canonical component payloads

If raw status already contains `software` or `updater` tables, it is treated as canonical and copied forward with light normalisation:

- `available` defaults to `true` unless explicitly `false`
- `ready` defaults to `true` unless explicitly `false`
- `software`, `updater`, and `capabilities` are normalised to tables

#### B. Plain status payloads

Otherwise the service derives a canonical form from the source payload:

- `software.version` from `raw.version` or `raw.fw_version`
- `software.build` from `raw.build`
- `software.image_id` from `raw.image_id`
- `software.boot_id` from `raw.boot_id`
- `updater.state` from `raw.updater_state`, else `raw.state`, else `raw.status`, else `raw.kind`
- `updater.last_error` from `raw.last_error` or `raw.err`
- `available = next(raw) ~= nil`
- `ready = raw.ready ~= false`

### MCU-specific normalisation

When a component resolves to subtype `mcu`, the service uses the MCU-specific normaliser.

Canonical MCU payloads are recognised when any of these are present:

- `software`
- `updater`
- `incarnation`

For plain MCU status payloads, the normaliser derives:

- `available = next(raw) ~= nil`
- `ready = raw.ready ~= false`
- `incarnation = raw.incarnation or raw.boot_id or nil`
- `software.version` from `raw.version` or `raw.fw_version`
- `software.build` from `raw.build`
- `software.image_id` from `raw.image_id`
- `software.boot_id` from `raw.boot_id`
- `updater.state` from `raw.updater_state`, else `raw.state`, else `raw.status`, else `raw.kind`
- `updater.last_error` from `raw.last_error` or `raw.err`
- `source` copied from `raw.source` if present
- `raw` as a deep copy of the original payload

For canonical MCU payloads, the normaliser preserves:

- `available`
- `ready`
- `incarnation`
- `software`
- `updater`
- `capabilities`
- `source`
- `health`
- `raw` (or the whole payload when `raw` is absent)

When the source is down, the shell still records `raw_status = { state = 'unavailable', err = <reason> }`; the MCU normaliser then projects that into an unavailable updater state in the same way as any other plain MCU payload.

### Derived fields

- `available = rec.source_up and base.available`
- `ready = available and base.ready`
- `capabilities.update = true` whenever the component has any actions
- `source.member`, `source.member_class`, `source.link_class`, and `source.role` are always derived from the component record
- `source.kind` defaults to `'host'` for host components and `'member'` otherwise when the source payload does not already provide a kind
- `health`:
  - use `base.health` if supplied by the source
  - otherwise `unknown` when unavailable
  - otherwise `degraded` when updater state is `failed` or `unavailable`
  - otherwise `ok`

## Summary payloads

### `state/device/components`

```lua
{
  kind = 'device.components',
  ts = <monotonic seconds>,
  components = {
    [<name>] = {
      class = <string>,
      subtype = <string>,
      role = <string>,
      member = <string>,
      member_class = <string>,
      link_class = <string|nil>,
      present = <boolean>,
      available = <boolean>,
      ready = <boolean>,
      health = <string>,
      actions = { ... },
      software = { ... },
      updater = { ... },
    },
  },
  counts = {
    total = <integer>,
    available = <integer>,
    degraded = <integer>,
  },
}
```

`degraded` counts every component whose health is not `'ok'`.

### `state/device/self`

```lua
{
  kind = 'device.self',
  ts = <monotonic seconds>,
  counts = { ... },
  components = { ... },
}
```

This is a thin wrapper over the same component summary used by `state/device/components`.

### `state/device/component/<name>/software`

A projected copy of `component.software` plus:

- `kind = 'device.component.software'`
- `ts`
- `component`
- `role`
- `member`
- `member_class`
- `link_class`

### `state/device/component/<name>/update`

A projected copy of `component.updater` plus:

- `kind = 'device.component.update'`
- `ts`
- `component`
- `available`
- `health`
- `actions`

## Service flow

```mermaid
flowchart TD
  St[Start] --> A(Watch retained cfg/device)
  A --> B(Bind cmd/device/get, component/list, component/get, component/do)
  B --> C(Build default component map)
  C --> D(Spawn one observer child per component)
  D --> E{choice: cfg, observer event, get, list, self, do, changed pulse}
  E -->|cfg retain/unretain| F(Apply config, unretain removed topics, rebuild observers)
  F --> G(Signal changed)
  G --> E
  E -->|raw_changed| H(Update raw_status/source_up)
  H --> G
  E -->|source_down| I(Mark unavailable and keep reason)
  I --> G
  E -->|changed pulse| J(Publish dirty component topics)
  J --> K(Publish summary and self if dirty)
  K --> E
  E -->|component/get| L(Reply from cache or fetch on demand via get_topic)
  L --> E
  E -->|component/list / device/get / component/do| M(Reply immediately)
  M --> E
```

## Architecture notes

- the service is intentionally thin: no HAL calls, no component-specific policy, no direct fabric coupling
- the default `cm5` host component ensures there is always a stable local host façade even without retained config
- source-specific detail is preserved in `raw` and lightly interpreted into canonical `software`, `updater`, and `source` sections
- local and member-backed components are deliberately projected into the same shape so that UI, update, and higher-level services can treat them uniformly
