# Device Service

## Purpose

The Device service is the appliance-facing façade over configured components.
It does not implement drivers, transport, or device policy. Instead it:

1. consumes retained `cfg/device`
2. maintains an in-memory component table
3. supervises one fact-backed observer child per configured component
4. composes canonical retained device state under `state/device/...`
5. exposes local command topics for aggregate reads, component reads, and component actions

The service is intentionally thin. It consumes retained fact topics named by each component definition and republishes a stable local shape for the rest of DeviceCode.

## Dependencies

### Retained configuration

| Topic | Purpose |
|---|---|
| `{'cfg','device'}` | Device component configuration. Retained and replayed on startup. |

### Consumed topics and calls

The service has no direct HAL dependency. It consumes retained fact topics and component action call topics named by each component definition.

| Config field | Purpose |
|---|---|
| `facts.<name>` | Retained fact topic watched for that component fact. |
| `actions.<name>` | Call topic used by `cmd/device/component/do` for that action. |
| `provider_opts` | Provider options passed to the fact watcher. |

### Built-in default component

Even with no retained config, the service includes a built-in `cm5` host component:

```lua
cm5 = {
  class = 'host',
  subtype = 'cm5',
  role = 'primary',
  member = 'local',
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

      provider_opts = <table|nil>,

      facts = {
        [<fact_name>] = <topic>,
      },

      actions = {
        [<action_name>] = <topic>,
      } | nil,
    },
  },
}
```

### Normalisation rules

- if `schema` is present and does not match `devicecode.config/device/1`, defaults are used
- configured components are merged by name over the built-in defaults
- every component is fact-backed
- `facts` must be a non-empty table
- each fact name must be a non-empty string
- each fact topic must be a non-empty topic array
- `actions.<name> = <topic>` is normalised to an operation record with `name` and `call_topic`
- the provider is always `fact_watch`
- `provider_opts` is copied through unchanged when present

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

- return the current locally composed component view
- no upstream fetch is performed

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

Providers are selected by `rec.provider` internally. The current service uses one built-in provider:

- `fact_watch`

`fact_watch` behaviour:

1. subscribe to each configured retained fact topic
2. build a dynamic choice over all fact subscriptions
3. for each received retained event:
   - on `retain`, emit `fact_changed` with `fact` and `payload`
   - on `unretain`, emit `fact_changed` with `fact` and `payload = nil`
4. if the watch closes or the provider faults, emit `source_down`

Shell-side effects:

- `fact_changed`:
  - `raw_facts[fact_name] = payload`
  - `fact_state[fact_name].seen = true`
  - `fact_state[fact_name].updated_at = now`
  - `source_up = true`
  - `source_err = nil`
- `source_down`:
  - keep the last seen fact cache intact
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
    facts = {
      [<fact_name>] = {
        watch_topic = <topic>,
      },
    },
    ...
  },
  raw = <component-specific raw projection|nil>,
}
```

### Projection rules

The service composes component state from retained fact sets.

#### Host / CM5 components

Host components compose the following fact families when present:

- `software`
- `updater`
- `health`

Derived rules:

- `available = true` once any fact has been seen and the source is up
- `ready = true` once `software` and `updater` have both been seen and the source is up
- `software` is copied from the retained software fact with light normalisation
- `updater` is copied from the retained updater fact with light normalisation
- `health` prefers the retained health fact; otherwise it is derived from availability and updater state
- `raw` contains a deep copy of the raw fact set

#### MCU components

MCU components compose the same fact families:

- `software`
- `updater`
- `health`

Derived rules:

- `available = true` once any fact has been seen and the source is up
- `ready = true` once `software` and `updater` have both been seen and the source is up
- `software` is copied from the retained software fact with light normalisation
- `updater` is copied from the retained updater fact with light normalisation
- `health` prefers the retained health fact; otherwise it is derived from availability and updater state
- `raw` contains a deep copy of the raw fact set

### Derived fields

- `available = rec.source_up and base.available`
- `ready = available and base.ready`
- `capabilities.update = true` whenever the component has any actions
- `source.member`, `source.member_class`, `source.link_class`, and `source.role` are always derived from the component record
- `source.kind` defaults to `'host'` for host components and `'member'` otherwise when the composed payload does not already provide a kind
- `health`:
  - use composed health if supplied
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
  C --> D(Spawn one fact observer child per component)
  D --> E{choice: cfg, observer event, get, list, self, do, changed pulse}
  E -->|cfg retain/unretain| F(Apply config, unretain removed topics, rebuild observers)
  F --> G(Signal changed)
  G --> E
  E -->|fact_changed| H(Update raw_facts and source_up)
  H --> G
  E -->|source_down| I(Mark source down and keep cached facts)
  I --> G
  E -->|changed pulse| J(Publish dirty component topics)
  J --> K(Publish summary and self if dirty)
  K --> E
  E -->|component/get| L(Reply from local composed state)
  L --> E
  E -->|component/list / device/get / component/do| M(Reply immediately)
  M --> E
```

## Architecture notes

- the service is intentionally thin: no HAL calls, no component-specific policy, no direct fabric coupling
- every component is fact-backed
- the default `cm5` host component ensures there is always a stable local host façade even without retained config
- local and member-backed components are deliberately projected into the same shape so that UI, update, and higher-level services can treat them uniformly
