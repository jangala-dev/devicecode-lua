# Update Service

## Purpose

The Update service owns durable update jobs.

It is responsible for:

1. creating, storing, listing, retrieving, retrying, cancelling and discarding jobs
2. normalising artefact inputs so the rest of the flow works on artefact refs and descriptor snapshots
3. delegating component-specific work to pluggable backends
4. persisting jobs through `control_store`
5. publishing one retained record per job plus an aggregate summary
6. running stage / commit / reconcile workers under a single active-job policy
7. resuming post-commit reconcile after restart
8. reconciling bundled desired state for configured components

The design is intentionally simple:
- one active job globally
- no scheduler beyond explicit create/start/commit actions and bundled desired-state reconcile
- component-specific mechanics in backends
- service-level policy, persistence and publication in the shell

## Dependencies

### Retained configuration

| Topic | Purpose |
|---|---|
| `{'cfg','update'}` | Update runtime configuration. Retained and replayed on startup. |

### Required capabilities

| Capability | Id | Purpose |
|---|---|---|
| `control_store` | `'update'` | Persist and reload update job records and bundled desired-state records. |
| `artifact_store` | `'main'` | Open, delete, import and stage artefacts. |
| `signature_verify` | `'main'` | Optional signature verification for bundled MCU images. |

The service discovers `control_store/update` and `artifact_store/main` before it becomes runnable. `signature_verify/main` is referenced through a capability ref and used when bundled image policy asks for verification.

### Consumed service endpoints

Backends call into the rest of the system through stable local services.

#### Through `device`

| Topic | Purpose |
|---|---|
| `{'cmd','device','component','do'}` | Dispatch `prepare_update`, `stage_update`, or `commit_update` for component backends. |

#### Through `fabric`

| Topic | Purpose |
|---|---|
| `{'cmd','fabric','transfer'}` | Stage remote artefacts to a member link for backends that use fabric transfer. |

### Observed retained state

The service observes retained state declared by active backends, currently including:

| Topic pattern | Purpose |
|---|---|
| `{'state','device','component', <component>}` | Component reconcile state |
| `{'state','fabric','link', <link_id>, 'transfer'}` | Fabric transfer progress for backends that declare a transfer link |

## Configuration

Retained payload on `{'cfg','update'}`:

```lua
{
  schema = 'devicecode.config/update/1',
  jobs_namespace = <string|nil>,
  reconcile = {
    interval_s = <number|nil>,
    timeout_s = <number|nil>,
  } | nil,
  artifacts = {
    default_policy = <string|nil>,
    policies = {
      [<component>] = <string>,
    } | nil,
  } | nil,
  components = {
    [<component>] = {
      backend = 'cm5_swupdate' | 'mcu_component',
      transfer = {
        link_id = <string|nil>,
        receiver = <topic|nil>,
        timeout_s = <number|nil>,
      } | nil,
      timeout_prepare = <number|nil>,
      timeout_stage = <number|nil>,
      timeout_commit = <number|nil>,
    },
  } | nil,
  bundled = {
    namespace = <string|nil>,
    components = {
      [<component>] = {
        enabled = <boolean>,
        follow_mode_default = 'auto' | 'hold' | nil,
        auto_start = <boolean|nil>,
        auto_commit = <boolean|nil>,
        retry_on_boot = <boolean|nil>,
        source = <table|nil>,
        target = <table|nil>,
        preflight = <table|nil>,
        cm5_release_id_field = <string|nil>,
      },
    } | nil,
  } | nil,
}
```

### Default configuration

```lua
{
  schema = 'devicecode.config/update/1',
  jobs_namespace = 'update/jobs',
  reconcile = {
    interval_s = 10.0,
    timeout_s = 180.0,
  },
  artifacts = {
    default_policy = 'transient_only',
    policies = {
      cm5 = 'transient_only',
      mcu = 'transient_only',
    },
  },
  components = {
    cm5 = { backend = 'cm5_swupdate' },
    mcu = { backend = 'mcu_component' },
  },
  bundled = {
    namespace = 'update/state/bundled',
    components = {},
  },
}
```

### Merge rules

- if `schema` is present and does not match `devicecode.config/update/1`, defaults are used
- `jobs_namespace` overrides the default when it is a non-empty string
- `reconcile.interval_s` and `reconcile.timeout_s` override defaults when positive numbers
- `artifacts.default_policy` and `artifacts.policies` override defaults when valid strings
- if `components` is present, it replaces the default component-backend table entirely
- `bundled.namespace` overrides the default namespace when non-empty
- each `bundled.components[component]` record is copied and normalised:
  - `enabled` is `true` only when explicitly true
  - `follow_mode_default` is `'hold'` only when explicitly set, otherwise `'auto'`
  - `auto_start`, `auto_commit`, and `retry_on_boot` default to `true`

## Exposed commands

| Topic | Purpose |
|---|---|
| `{'cmd','update','job','create'}` | Create a new job. |
| `{'cmd','update','job','do'}` | Apply one lifecycle action to an existing job. |
| `{'cmd','update','job','get'}` | Fetch one public job view. |
| `{'cmd','update','job','list'}` | Fetch all public job views. |

### `cmd/update/job/create`

Request:

```lua
{
  component = <string>,
  offer_id = <string|nil>,
  artifact = {
    kind = 'import_path' | 'ref' | 'bundled',
    ...kind-specific fields...
  },
  expected_image_id = <string|nil>,
  metadata = <table|nil>,
  options = {
    auto_start = <boolean|nil>,
    auto_commit = <boolean|nil>,
  } | nil,
}
```

Behaviour:
- validates `component`
- resolves the artefact through the artefact subsystem
- captures `artifact_ref` and descriptor snapshot into the job
- derives `expected_image_id` from bundled metadata when omitted and available
- sets bundled metadata fields automatically when `artifact.kind == 'bundled'`
- creates the job
- if `options.auto_start == true`, immediately starts the job and replies with the post-start public job view

Failures include:
- `component_required`
- `unknown_component`
- any artefact resolution error
- persistence failure

### `cmd/update/job/do`

Request:

```lua
{
  job_id = <string>,
  op = 'start' | 'commit' | 'cancel' | 'retry' | 'discard',
}
```

Supported operations:
- `start` -> transitions a `created` job into staging and spawns a stage runner
- `commit` -> transitions an `awaiting_commit` job into `awaiting_return` and spawns a commit runner
- `cancel` -> cancels a passive job (`created` or `awaiting_commit`)
- `retry` -> clones a retryable terminal job into a new `created` job and supersedes the old one
- `discard` -> discards a terminal job and unretains its retained record

Failures include:
- `invalid_op`
- `unknown_job`
- job-state-specific errors such as `job_not_startable`, `job_not_committable`, `job_active`, `job_terminal`, `job_not_retryable`, `job_not_discardable`
- admission failure from `can_activate`

### `cmd/update/job/get`

Request:

```lua
{ job_id = <string> }
```

Success reply:

```lua
{ ok = true, job = <public job view> }
```

Failure:
- `unknown_job`

### `cmd/update/job/list`

Request payload is ignored.

Success reply:

```lua
{ ok = true, jobs = { <public job view>, ... } }
```

## Artefact model

After creation, the service works on artefact refs plus descriptor snapshots.

### Supported input kinds

#### `import_path`

```lua
{
  kind = 'import_path',
  path = <string>,
}
```

The service imports the path through `artifact_store.import_path(...)` and stores the resulting artefact ref and descriptor snapshot.

#### `ref`

```lua
{
  kind = 'ref',
  ref = <string>,
}
```

The service opens the ref through `artifact_store.open(...)` and snapshots the descriptor.

#### `bundled`

```lua
{
  kind = 'bundled',
  ...optional selector/config fields...
}
```

The service resolves a bundled artefact for the target component through `Artifacts:import_bundled(...)`. For MCU images, this path can inspect and optionally verify a signed image bundle before it is imported into the artefact store.

### Retention policy

Import policy is chosen by:
1. `cfg.artifacts.policies[component]`
2. otherwise `cfg.artifacts.default_policy`
3. otherwise `'transient_only'`

Runtime behaviour also honours staged metadata from backends, notably `staged.artifact_retention`.

Current shell behaviour:
- if a staged result reports `artifact_retention == 'release'`, the service deletes the artefact after staging success
- terminal job discard also deletes any retained artefact ref before unretaining the job record
- jobs may also explicitly release their artefact on runtime failure or success paths as directed by the runtime module

## Job model

Top-level in-memory state:

```lua
{
  cfg = <merged service config>,
  store = { jobs = { [id] = job }, order = { id... } },
  seq = <monotonic in-service sequence>,
  active_job = { job_id, scope, component, started_at, mode } | nil,
  locks = { global = job_id | nil },
  backends = { [component] = backend },
  dirty_jobs = { [job_id] = true },
  summary_dirty = <boolean>,
  component_obs = { [key] = observer_rec },
}
```

Persisted durable job fields include:

```lua
{
  job_id = <string>,
  offer_id = <string|nil>,
  component = <string>,
  artifact_ref = <string|nil>,
  artifact_meta = <table|nil>,
  expected_image_id = <string|nil>,
  metadata = <table|nil>,
  auto_start = <boolean>,
  auto_commit = <boolean>,
  state = <string>,
  stage = <string>,
  next_step = <string|nil>,
  created_seq = <integer>,
  updated_seq = <integer>,
  created_mono = <number>,
  updated_mono = <number>,
  result = <table|nil>,
  error = <string|nil>,
  pre_commit_boot_id = <string|nil>,
  artifact_released_at = <number|nil>,
  staged_meta = <table|nil>,
  runtime = {
    phase_run_id = <string|nil>,
    phase_mono = <number|nil>,
    awaiting_return_run_id = <string|nil>,
    awaiting_return_mono = <number|nil>,
    progress = <table|nil>,
  },
}
```

### Lifecycle states

Active states:
- `staging`
- `awaiting_return`

Passive states:
- `created`
- `awaiting_commit`

Terminal states:
- `succeeded`
- `failed`
- `rolled_back`
- `cancelled`
- `timed_out`
- `superseded`
- `discarded`

Current shell policy is single-active globally through `locks.global`.

## Retained topics published

| Topic | Payload |
|---|---|
| `{'state','update','jobs', <job_id>}` | public job view |
| `{'state','update','summary'}` | aggregate summary |
| `{'state','update','bundled', <component>}` | bundled desired-state record for that component |

### Public job view

Retained under `state/update/jobs/<job_id>` as:

```lua
{
  job = {
    job_id = <string>,
    component = <string>,
    source = { offer_id = <string|nil> },
    artifact = {
      ref = <string|nil>,
      meta = <table|nil>,
      expected_image_id = <string|nil>,
      released_at = <number|nil>,
      retention = <string|nil>,
    },
    lifecycle = {
      state = <string>,
      stage = <string>,
      next_step = <string|nil>,
      created_seq = <integer>,
      updated_seq = <integer>,
      created_mono = <number>,
      updated_mono = <number>,
      error = <string|nil>,
    },
    progress = <table|nil>,
    observation = {
      pre_commit_boot_id = <string|nil>,
    },
    actions = <job action table>,
    result = <table|nil>,
    metadata = <table|nil>,
    engagement = {
      commit_required = <boolean>,
      commit_mode = <string|nil>,
    },
  },
}
```

`commit_required` is derived from `metadata.require_explicit_commit` or `metadata.commit_policy == 'manual'`.

### Summary payload

`state/update/summary` retains:

```lua
{
  kind = 'update.summary',
  jobs = { <public job view>, ... },
  counts = {
    total = <integer>,
    active = <integer>,
    terminal = <integer>,
    awaiting_commit = <integer>,
    awaiting_return = <integer>,
    created = <integer>,
    failed = <integer>,
    succeeded = <integer>,
    ...other state counts as present...
  },
  active = {
    job_id = <string>,
    component = <string>,
    state = <string>,
    since = <number>,
  } | nil,
  locks = <copy of state.locks>,
}
```

### Bundled desired-state record

`state/update/bundled/<component>` stores the service’s long-lived reconcile state for that component, including fields such as:
- `follow_mode`
- `desired`
- `sync_state`
- `last_result`
- `last_attempt_job_id`
- `last_manual_job_id`
- `updated_at`

The exact shape is intentionally data-driven and stored through the bundled-state store rather than a dedicated schema module.

## Runtime and reconciliation behaviour

### Backends

Built-in backends are:
- `cm5_swupdate`
- `mcu_component`

All backends must implement:
- `prepare`
- `stage`
- `commit`
- `evaluate`

Backends may also implement `observe_specs(cfg)` to declare retained observations required for reconcile.

### Stage/commit runtime

The service runtime owns:
- spawning stage runners
- spawning commit runners
- adopting incomplete jobs on startup
- releasing active locks
- consuming runner mailbox events

Important shell helpers include:
- `enter_awaiting_return(job, stage, result, opts)`
- post-stage release of transient artefacts when appropriate
- post-commit startup reconcile

### Observation-driven reconcile

The service rebuilds backend observation watches from current config/backends and consumes observed retained state as first-class events. Reconcile is driven by:
- changed observations
- service restart adoption
- bundled desired-state reconcile passes
- timeout logic using `cfg.reconcile.timeout_s`

### Bundled desired-state reconcile

When enabled for a component, bundled reconcile:
- identifies the current CM5 release from the `cm5` component software state
- probes the bundled artefact for the component and derives desired image identity
- compares desired image identity with the current component software identity
- records long-lived follow/hold state in the bundled store
- creates and optionally auto-starts/auto-commits normal update jobs when the current component diverges from the desired bundled image

Bundled reconcile never bypasses the normal job model; it creates ordinary jobs and feeds them through the same update machinery.
