# Update Service

## Purpose

The Update service owns **update-domain policy, durable update jobs, artefact ingest workflows, active-job coordination, post-commit adoption, and bundled desired-state reconcile**.

It is responsible for:

1. creating, storing, listing, retrieving, retrying, cancelling and discarding update jobs
2. creating, appending to, committing and aborting artefact-ingest instances
3. normalising artefact inputs so the rest of the flow operates on artefact refs plus descriptor snapshots
4. delegating component-specific mechanics to pluggable backends
5. persisting durable update and bundled-reconcile state through `control_store`
6. publishing:

   * one retained workflow record per update job
   * one retained workflow record per ingest instance
   * retained update-domain summaries
7. running stage / commit / reconcile workers under a single active-job policy
8. adopting incomplete post-commit reconcile after restart
9. reconciling bundled desired state for configured components

The design is intentionally simple:

* one active update job globally
* no scheduler beyond explicit manager actions and bundled desired-state reconcile
* component-specific mechanics live in backends
* policy, persistence, lifecycle control and publication live in the service shell

The service is the semantic owner of:

* `cap/update-manager/...`
* `cap/artifact-ingest/...`
* `state/workflow/update-job/...`
* `state/workflow/artifact-ingest/...`
* `state/update/...`

It is **not** the owner of component truth under `state/device/...`, nor of raw provider-native update mechanics under `raw/...`.

---

## Public surfaces

### Service lifecycle

| Topic                       | Purpose                         |
| --------------------------- | ------------------------------- |
| `{'svc','update','status'}` | Service lifecycle and readiness |
| `{'svc','update','meta'}`   | Service metadata                |

### Intended configuration

| Topic              | Purpose                               |
| ------------------ | ------------------------------------- |
| `{'cfg','update'}` | Retained update runtime configuration |

### Stable public manager interfaces

| Topic                                                   | Purpose                                            |
| ------------------------------------------------------- | -------------------------------------------------- |
| `{'cap','update-manager','main','meta'}`                | Manager metadata                                   |
| `{'cap','update-manager','main','status'}`              | Broad manager availability                         |
| `{'cap','update-manager','main','rpc','create-job'}`    | Create a new update job                            |
| `{'cap','update-manager','main','rpc','start-job'}`     | Start a created job                                |
| `{'cap','update-manager','main','rpc','commit-job'}`    | Commit an awaiting-commit job                      |
| `{'cap','update-manager','main','rpc','cancel-job'}`    | Cancel a passive job                               |
| `{'cap','update-manager','main','rpc','retry-job'}`     | Retry a retryable terminal job                     |
| `{'cap','update-manager','main','rpc','discard-job'}`   | Discard a terminal job                             |
| `{'cap','update-manager','main','rpc','get-job'}`       | Fetch one public job view                          |
| `{'cap','update-manager','main','rpc','list-jobs'}`     | Fetch all public job views                         |
| `{'cap','update-manager','main','event','job-changed'}` | Non-authoritative wake/audit event for job changes |

| Topic                                                         | Purpose                                               |
| ------------------------------------------------------------- | ----------------------------------------------------- |
| `{'cap','artifact-ingest','main','meta'}`                     | Ingest manager metadata                               |
| `{'cap','artifact-ingest','main','status'}`                   | Broad ingest manager availability                     |
| `{'cap','artifact-ingest','main','rpc','create'}`             | Create an ingest instance                             |
| `{'cap','artifact-ingest','main','rpc','append'}`             | Append bytes/chunks                                   |
| `{'cap','artifact-ingest','main','rpc','commit'}`             | Finalise ingest into an artefact                      |
| `{'cap','artifact-ingest','main','rpc','abort'}`              | Abort an ingest instance                              |
| `{'cap','artifact-ingest','main','event','instance-changed'}` | Non-authoritative wake/audit event for ingest changes |

### Canonical retained workflow truth

| Topic                                                 | Payload                                |
| ----------------------------------------------------- | -------------------------------------- |
| `{'state','workflow','update-job', <job_id>}`         | Public retained update-job record      |
| `{'state','workflow','artifact-ingest', <ingest_id>}` | Public retained artefact-ingest record |

### Canonical retained update-domain truth

| Topic                                         | Payload                                  |
| --------------------------------------------- | ---------------------------------------- |
| `{'state','update','summary'}`                | Aggregate update-domain summary          |
| `{'state','update','component', <component>}` | Component-level update/reconcile summary |

The service no longer uses public `cmd/update/...` trees, and job truth no longer lives under `state/update/jobs/...`.

---

## Dependencies

### Retained configuration

| Topic              | Purpose                                                         |
| ------------------ | --------------------------------------------------------------- |
| `{'cfg','update'}` | Update runtime configuration. Retained and replayed on startup. |

### Required capabilities

| Capability         | Id         | Purpose                                                                      |
| ------------------ | ---------- | ---------------------------------------------------------------------------- |
| `control_store`    | `'update'` | Persist and reload durable update-job records and bundled-reconcile records. |
| `artifact_store`   | `'main'`   | Open, delete, import and stage artefacts.                                    |
| `signature_verify` | `'main'`   | Optional signature verification for bundled MCU images.                      |

The service discovers `control_store/update` and `artifact_store/main` before it becomes runnable.

`signature_verify/main` is optional and is used only when bundled-image policy requires verification.

### Consumed stable local interfaces

Backends call into the rest of the system through stable public interfaces, not old `cmd/...` trees.

#### Through `device`

| Topic pattern                                       | Purpose                                                                                         |
| --------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `{'cap','component', <component>, 'rpc', <method>}` | Dispatch `prepare-update`, `stage-update`, `commit-update`, or other curated component methods. |

#### Through `fabric`

| Topic                                                 | Purpose                                                                                          |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `{'cap','transfer-manager','main','rpc','send-blob'}` | Send staged artefacts across a member/peer link where a backend uses transfer-manager semantics. |

### Observed retained state

The service observes retained state declared by active backends, currently including patterns such as:

| Topic pattern                                 | Purpose                                                                    |
| --------------------------------------------- | -------------------------------------------------------------------------- |
| `{'state','device','component', <component>}` | Component software/update summary used by reconcile                        |
| `{'state','fabric','link', <link_id>, ...}`   | Link/session/transfer summary used by transfer-aware backends              |
| `{'raw','member', <source>, ...}`             | Optional provenance-bearing imported member truth where a backend needs it |

The service should prefer canonical public retained truth where available, and use `raw/...` only where provenance or provider-native detail is genuinely required.

---

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

* if `schema` is present and does not match `devicecode.config/update/1`, defaults are used
* `jobs_namespace` overrides the default when it is a non-empty string
* `reconcile.interval_s` and `reconcile.timeout_s` override defaults when positive numbers
* `artifacts.default_policy` and `artifacts.policies` override defaults when valid values
* if `components` is present, it replaces the default component-backend table entirely
* `bundled.namespace` overrides the default namespace when non-empty
* each `bundled.components[component]` record is copied and normalised:

  * `enabled` is `true` only when explicitly true
  * `follow_mode_default` is `'hold'` only when explicitly set, otherwise `'auto'`
  * `auto_start`, `auto_commit`, and `retry_on_boot` default to `true`

### Configuration role

`cfg/update` is the canonical home of durable intended update behaviour.

It is **not** the home of current workflow truth, and it is **not** the same thing as component update state.

---

## Exposed manager methods

## `cap/update-manager/main/rpc/create-job`

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

* validates `component`
* resolves the artefact through the artefact subsystem
* captures `artifact_ref` and descriptor snapshot into the job
* derives `expected_image_id` from bundled metadata when omitted and available
* sets bundled metadata fields automatically when `artifact.kind == 'bundled'`
* creates the job
* if `options.auto_start == true`, immediately starts the job and replies with the post-start public job view

Failures include:

* `component_required`
* `unknown_component`
* artefact resolution errors
* persistence failure

## `cap/update-manager/main/rpc/start-job`

Request:

```lua
{ job_id = <string> }
```

Behaviour:

* transitions a `created` job into active staging
* acquires admission through the single-active policy
* spawns the stage worker

Failures include:

* `unknown_job`
* `job_not_startable`
* `job_active`
* admission failure from `can_activate`

## `cap/update-manager/main/rpc/commit-job`

Request:

```lua
{ job_id = <string> }
```

Behaviour:

* transitions an `awaiting_commit` job into active commit / awaiting-return flow
* spawns the commit worker

Failures include:

* `unknown_job`
* `job_not_committable`
* `job_active`

## `cap/update-manager/main/rpc/cancel-job`

Request:

```lua
{ job_id = <string> }
```

Behaviour:

* cancels a passive job (`created` or `awaiting_commit`)

Failures include:

* `unknown_job`
* `job_not_cancellable`
* `job_active`

## `cap/update-manager/main/rpc/retry-job`

Request:

```lua
{ job_id = <string> }
```

Behaviour:

* clones a retryable terminal job into a new `created` job
* supersedes the old job

Failures include:

* `unknown_job`
* `job_not_retryable`

## `cap/update-manager/main/rpc/discard-job`

Request:

```lua
{ job_id = <string> }
```

Behaviour:

* discards a terminal job
* deletes any retained artefact ref that must be released on discard
* unretains the workflow record

Failures include:

* `unknown_job`
* `job_not_discardable`

## `cap/update-manager/main/rpc/get-job`

Request:

```lua
{ job_id = <string> }
```

Success reply:

```lua
{ ok = true, job = <public job view> }
```

Failure:

* `unknown_job`

## `cap/update-manager/main/rpc/list-jobs`

Request payload is ignored.

Success reply:

```lua
{ ok = true, jobs = { <public job view>, ... } }
```

---

## Artefact-ingest manager

## `cap/artifact-ingest/main/rpc/create`

Creates an ingest instance and returns an ingest id.

## `cap/artifact-ingest/main/rpc/append`

Appends bytes or chunks to an existing ingest instance.

## `cap/artifact-ingest/main/rpc/commit`

Finalises the ingest instance into an artefact in `artifact_store` and yields a ref/descriptor snapshot suitable for use by update jobs.

## `cap/artifact-ingest/main/rpc/abort`

Aborts and cleans up an ingest instance.

The canonical retained truth for these instances lives under:

* `state/workflow/artifact-ingest/<id>`

not under UI-local or update-job-local trees.

---

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

The service imports the path through `artifact_store.import_path(...)` and stores the resulting artefact ref plus descriptor snapshot.

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

The service resolves a bundled artefact for the target component through the bundled artefact path. For MCU images, this path may inspect and optionally verify a signed image bundle before it is imported into the artefact store.

### Retention policy

Import policy is chosen by:

1. `cfg.artifacts.policies[component]`
2. otherwise `cfg.artifacts.default_policy`
3. otherwise `'transient_only'`

Runtime behaviour also honours staged metadata from backends, notably `staged.artifact_retention`.

Current service behaviour:

* if a staged result reports `artifact_retention == 'release'`, the service releases the artefact after staging success
* terminal discard also releases any retained artefact ref before unretaining the workflow record
* jobs may also explicitly release their artefact on runtime failure or success paths as directed by the runtime module

---

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

* `staging`
* `awaiting_return`

Passive states:

* `created`
* `awaiting_commit`

Terminal states:

* `succeeded`
* `failed`
* `rolled_back`
* `cancelled`
* `timed_out`
* `superseded`
* `discarded`

Current shell policy is single-active globally through `locks.global`.

---

## Canonical retained topics published

| Topic                                                 | Payload                                  |
| ----------------------------------------------------- | ---------------------------------------- |
| `{'state','workflow','update-job', <job_id>}`         | public retained update-job view          |
| `{'state','workflow','artifact-ingest', <ingest_id>}` | public retained ingest view              |
| `{'state','update','summary'}`                        | aggregate update-domain summary          |
| `{'state','update','component', <component>}`         | component-level reconcile/update summary |

### Public update-job view

Retained under `state/workflow/update-job/<job_id>` as:

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

### Public ingest view

Retained under `state/workflow/artifact-ingest/<ingest_id>` as a public view of the ingest instance, including fields such as:

* `ingest_id`
* `state`
* `source`
* `meta`
* `policy`
* `bytes_received`
* `artifact_ref`
* `error`
* `created_mono`
* `updated_mono`

### Summary payload

`state/update/summary` retains an aggregate update-domain summary, including:

* public job list or job-derived summaries
* counts by lifecycle class/state
* the currently active job, if any
* lock summary

### Component summary payload

`state/update/component/<component>` retains the long-lived update/reconcile summary for that component, including fields such as:

* `follow_mode`
* `desired`
* `sync_state`
* `last_result`
* `last_attempt_job_id`
* `last_manual_job_id`
* `updated_at`

This replaces the older public `state/update/bundled/<component>` shape as the canonical update-domain surface.

---

## Runtime and reconciliation behaviour

### Backends

Built-in backends are:

* `cm5_swupdate`
* `mcu_component`

All backends must implement:

* `prepare`
* `stage`
* `commit`
* `evaluate`

Backends may also implement `observe_specs(cfg)` to declare retained observations required for reconcile.

### Stage/commit runtime

The runtime owns:

* spawning stage workers
* spawning commit workers
* adopting incomplete jobs on startup
* releasing active locks
* consuming runner mailbox events

Important shell helpers include:

* transition into awaiting-return after successful commit handoff
* release of transient artefacts when appropriate
* post-commit startup adoption/reconcile

### Observation-driven reconcile

The service rebuilds backend observation watches from current config and current backends and consumes observed retained state as first-class inputs.

Reconcile is driven by:

* changed observations
* service restart adoption
* bundled desired-state reconcile passes
* timeout logic using `cfg.reconcile.timeout_s`

### Bundled desired-state reconcile

When enabled for a component, bundled reconcile:

* identifies the current CM5 release from the `cm5` component software state where relevant
* probes the bundled artefact for the component and derives desired image identity
* compares desired image identity with the current component software identity
* records long-lived follow/hold and reconcile summary in `state/update/component/<component>`
* creates and optionally auto-starts / auto-commits ordinary update jobs when the current component diverges from the desired bundled image

Bundled reconcile never bypasses the normal job model. It creates ordinary jobs and feeds them through the same update machinery.

---

## Observability

The service may emit non-retained observability under `obs/v1/update/...` for:

* audit
* job lifecycle traces
* ingest traces
* reconcile traces
* counters and metrics
* failure diagnostics

These events are useful for history and debugging, but they are **not** canonical truth.

Canonical current truth remains in:

* `state/workflow/update-job/...`
* `state/workflow/artifact-ingest/...`
* `state/update/...`

