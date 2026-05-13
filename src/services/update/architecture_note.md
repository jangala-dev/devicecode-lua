# Update architecture note

> **Basis of this note**
>
> This architecture follows the Fabric doctrine and the current `fibers` runtime contracts:
>
> * Ops describe what may wake a fibre.
> * Scopes describe what owns a lifetime.
> * `fibers.perform` waits under the current scope.
> * `perform_raw` belongs to infrastructure.
> * Scope cancellation is downward, cooperative, and scope-owned.
> * Parentage is the structural ownership mechanism.
> * `join_op()` is active finalisation, not passive observation.
> * Coordinators decide what events mean.
> * Workers perform blocking work inside owned scopes.
> * Finalisers release owned resources now.
> * Stored completions must exist before reporting.
> * `named_choice`, `choice`, and `first_ready` select readiness, not semantic priority.
>
> Where safety requires semantic priority between already-ready events, Update must use `devicecode/support/priority_event.lua`.

---

## 1. Purpose

`update` owns firmware update workflow for one firmware node.

It should provide:

```text
durable update jobs
artifact ingestion
artifact resolution and preflight
component-specific stage, commit, and reconcile operations
single-active-update admission
restart adoption
bundled-image policy
observable update state
manager and ingest APIs
clear ownership of artifacts, sinks, requests, active work, and durable state
```

The service must remain responsive under:

```text
slow storage
slow artifact import
device or HAL delays
upload interruption
component reboot
manager cancellation
link or service shutdown
restart after partial progress
publication failure
stale completions
```

The core rule is:

```text
Update policy is coordinated.
Update durability is owned by job_runtime.
Update execution is owned by active_runtime.
Update resources are owned by finalisers.
Update results are reported as completions.
```

The shortest form is:

```text
Generation admits.
Job runtime persists.
Active runtime executes.
Workers report facts.
Job runtime applies facts.
Publisher projects.
```

---

## 2. Service discipline

Ordinary update service code uses the scope-aware performer:

```lua
local ev = fibers.perform(next_event_op(state))
```

This means:

```text
wait for this semantic event while the current scope remains healthy
```

The service should not normally turn its own scope cancellation into a service event:

```lua
fibers.named_choice{
  event = next_event_op(state),
  stop  = scope:cancel_op(),
}
```

Own-scope cancellation is a lifetime fact. It should usually exit through `fibers.perform`.

A coordinator loop should look like:

```lua
while true do
  local ev = fibers.perform(next_event_op(state))

  local decision = reduce_event(state, ev)
  dispatch_effects_nonblocking(state, decision.effects)
end
```

Coordinator branches must remain:

```text
short
bounded
non-suspending
idempotent where possible
stale-safe where possible
rollback-safe where necessary
```

---

## 3. `perform_raw`

Update service code must not use `op.perform_raw`.

`perform_raw` belongs in:

```text
scope and runtime infrastructure
low-level Op tests
support helpers that deliberately bypass current-scope cancellation
exceptional infrastructure with explicit documentation
```

Normal update code uses:

```lua
fibers.perform(ev)
```

Blocking update behaviour should be represented by Ops and scopes, not by bypassing the current scope.

---

## 4. Target lifetime tree

Target shape:

```text
update service scope
  service coordinator
  service model
  service publisher
  capability publication cleanup

  job_runtime scope
    durable job coordinator
    job repository model
    control-store worker scopes
    transition worker scopes
    adoption worker scopes
    job model

  active_runtime scope
    active slot coordinator
    active job scope
      stage operation scope
      commit operation scope
      reconcile operation scope

  generation scope
    generation coordinator
    config snapshot
    component observers
    request root scope
    bundled coordinator

    manager request scopes
      create-job scope
      start-job scope
      commit-job scope
      retry/cancel/discard scopes where needed

    ingest instance scopes
      artifact sink lifetime
      append/commit/abort operation scopes where needed

    HAL/backend operation scopes
      artifact-store import/open/delete/sink operations
      device prepare/stage/commit operations
      image inspection or verification operations
```

The `active_runtime` is likewise service-owned. It is not a generation-local lifetime. A generation may admit durable active intent, but active execution follows service-owned durable state and may outlive the generation that admitted it. Generation replacement must not cancel already accepted active work.

The `job_runtime` is not merely a helper for generation state. It is the durable authority for jobs.

A generation may cache job snapshots, but those snapshots are never authority.

A manager request scope may wait for durable transition results, but it must not directly perform durable mutation.

An active worker may report work facts, but it must not directly update durable job state.

Introduce a scope when work has any of:

```text
identity
owned resources
cleanup
child tasks
timeout ownership
retry state
durable side effects
request ownership
diagnostics
meaningful completion
```

A spawned fibre is not an ownership boundary. A scope is. Use `fibers.spawn` for current-scope work, `scope:spawn` only when the target scope is deliberately chosen, and `scoped_work.start` for meaningful child work.

---

## 5. Roles

Keep these roles distinct.

```text
Update service coordinator
  Owns the top-level service lifecycle.
  Starts and stops generations.
  Starts and supervises job_runtime.
  Publishes service capability.
  Does not do update work inline.

Generation coordinator
  Owns generation-local policy.
  Owns current config, component observers, bundled policy, generation-local admission, and generation-local models.
  Starts scoped work and applies generation-local completions.
  Does not call HAL, backend, store, or artifact operations inline.
  Does not own durable job truth.

Job runtime
  Owns durable job truth.
  Owns job transitions.
  Owns job repository loading, saving, adoption, and deletion.
  Owns the durable job model.
  Applies admitted facts to durable state.
  Serialises or otherwise controls durable mutation.
  Reports durable state changes to observers.

Active runtime
  Owns active execution admission and active slot state.
  Starts active job work only after durable active intent exists.
  Stores active work completion before reporting.
  Releases the active slot from stored active completion.
  Does not mutate durable job state directly.

Manager request scope
  Owns a caller-visible request.
  Owns request_owner finalisation.
  Performs blocking validation, artifact resolution, preflight, or admission work.
  May submit durable transition requests to job_runtime and wait for results.
  Does not itself become the durable owner after transition admission.

Ingest instance scope
  Owns an artifact sink handle.
  Owns upload lifecycle and sink finalisation.
  Terminates the sink from its finaliser.

Active job scope
  Owns one active update phase or phase sequence.
  Performs stage, commit, or reconcile work.

  Returns one result table.
  Lets ordinary errors and cancellation escape.

Backend/HAL operation scope
  Owns one blocking call or small blocking sequence against HAL, device, store, crypto, or artifact APIs.
  Returns a result table or fails.

Bundled coordinator
  Owns desired-versus-current bundled policy.
  Starts probe and job work.
  Does not probe artifacts inline.

Publisher
  Observes models.
  Publishes retained public state.
  Does not decide update policy.

Model
  Stores observable snapshots.
  Exposes versioned changed_op.
  Does not perform Ops.

Finaliser
  Releases owned resources immediately.
  Does not wait.
```

---

## 5a. Event ports, not parent callbacks

Update service code should be callback-free across ownership boundaries. A child
component may report an event to an event port; it must not call back into the
parent coordinator to mutate parent state.

Use the common vocabulary consistently:

```text
component    scoped child with identity and owned resources
source       producer of service events
event        immutable coordinator input
record       coordinator-owned state for one child, request, or generation
generation   version boundary for config-derived work
adapter      explicit edge boundary for external non-Op code
```

The allowed direction is:

```text
component -> service event port -> coordinator -> model/effects
```

not:

```text
component -> on_snapshot/on_done/on_changed callback -> parent state
```

`devicecode.support.service_events` is the common helper for event ports. It stamps
source identity, supports route events for mixed request queues, and uses the
public queue helpers for immediate, explicit admission.


---

## 6. Durable authority

Durability is not a side effect of requests. Durability is a runtime with its own authority.

The `job_runtime` is the single authority for durable job state.

This means:

```text
Only job_runtime admits durable job transitions.
Only job_runtime applies durable job transitions.
Only job_runtime decides the persisted job state resulting from accepted facts.
Only job_runtime owns restart adoption of persisted jobs.
```

Other components may hold cached or projected state:

```text
generation coordinator
  may cache snapshots for cheap policy checks

active_runtime
  may hold active identity and slot state

publisher
  may hold retained projection state

manager request scopes
  may hold request-local views and transition results
```

These are not durable authority.

The durable boundary is crossed only through explicit transition submission.

---

## 7. Durable transition vocabulary

A durable transition should have an explicit lifecycle.

Recommended states:

```text
proposed
admitted
persisting
persisted
rejected
failed
superseded
```

The most important distinction is:

```text
rejected before admission
failed after admission
```

A rejected transition means no durable effect has been accepted.

A failed transition means durable authority has accepted responsibility and must account for the outcome.

For example:

```text
start-job rejected
  no active intent has been persisted
  no active work may start

start-job admitted then failed
  job_runtime must record, expose, or recover the failure according to policy
```

This distinction is central to cancellation, restart, and request reply behaviour.

---

## 8. Transition submission

A representative API is:

```lua
local h = assert(job_runtime:admit_transition({
  kind       = "start_job",
  generation = generation,
  job_id     = job_id,
  request_id = request_id,

  expected = {
    status = "created",
  },

  patch = {
    status = "staging",
    active_intent = {
      phase = "stage",
      token = active_token,
    },
  },
})
```

The exact API may differ, but the contract must not.

`admit_transition` is immediate and non-suspending. It allocates transition identity, copies the command, admits it to the runtime queue, and returns a handle. Persistence is owned by the runtime worker and observed through `handle:outcome_op()`.

If the caller is cancelled after admission, `job_runtime` must still complete or account for the transition.

The request scope owns the caller-visible request. It does not own the durable mutation once the transition has been admitted.

A transition result should say at least:

```lua
{
  transition_id = transition_id,
  status        = "persisted", -- or "rejected" / "failed" / "superseded"
  job_id        = job_id,
  job           = job_snapshot_or_nil,
  reason        = reason_or_nil,
}
```

If the transition is rejected before admission, the request may reply with a normal rejection.

If the transition is admitted, failure must be handled as a durable fact.

---

## 9. Active intent and active execution

Active execution must not begin before durable active intent exists.

The intended sequence is normative:

```text
1. job_runtime persists active intent.
2. active_runtime receives authority to execute.
3. active_runtime starts scoped active work.
4. active_runtime stores completion.
5. job_runtime applies completion to durable state.
6. active_runtime releases the slot.
```

For stage:

```text
persist job.state = "staging" and active_intent.phase = "stage"
then start active stage scope
```

For commit:

```text
persist job.state = "committing" and active_intent.phase = "commit"
then start active commit scope
```

For reconcile:

```text
persist job.state = "awaiting_return"
then start reconcile scope
```

This prevents a restart from observing active work that was never durably intended.

It also prevents a request scope from reporting accepted active work before the durable authority can adopt or recover it.

---

## 10. Service and generation relationship

A generation is the current interpretation of update configuration.

A generation owns:

```text
cfg/update snapshot
component backend set
component observer set
bundled policy state
generation-local request admission
generation-local models
```

A generation does not own durable job truth.

A generation may become stale. Durable job truth does not become stale merely because a generation closes.

Generation identity is used to reject stale policy decisions, not to invalidate durable facts already admitted.

A material config change should either:

```text
patch a known-safe subset of the existing generation
```

or:

```text
cancel the old generation and start a new one
```

Namespace changes, component topology changes, backend changes, artifact-store changes, and bundled policy changes should normally start a new generation.

Generation startup should be scoped work:

```text
read config
discover required capabilities
connect to job_runtime
start component observers
initialise bundled policy
publish initial model
open generation-local admission
```

Durable restart adoption belongs primarily to `job_runtime`, though generation policy may influence what adoption actions are requested.

Generation close is a safety boundary. Once generation close is ready, new admission into that generation must not proceed ahead of it. This is a valid use of `priority_event`.

---

## 11. Coordinator rule

A strict update coordinator has one suspending point: its control point.

```lua
while true do
  local ev = fibers.perform(next_event_op(state))

  local decision = reduce_event(state, ev)
  dispatch_effects_nonblocking(state, decision.effects)
end
```

Coordinator branches may:

```text
mutate coordinator-owned state
start scoped work
cancel scoped work
grant or reject an active-slot lease
record pending work
ignore stale completions
resolve or fail in-memory request owners immediately
update models
use documented immediate queue or bus helpers
```

Coordinator branches must not:

```text
join child scopes
sleep
perform stream I/O
perform bus calls
perform HAL/device/artifact/control-store work
call run_scope_op for child work
block on queue capacity
call close_op
call perform_raw
```

If work may wait, it belongs in a worker, scoped operation, reporter, I/O owner, publisher, or runtime component.

---

## 12. Semantic events

The update coordinator should wait on semantic events, not raw readiness.

Good event types:

```text
config changed
generation closed
manager request received
ingest request received
component observer changed
job transition completed
job model changed
artifact operation completed
active job completed
active job progress changed
bundled probe completed
publisher faulted
job_runtime failed
generation completed
```

Avoid exposing raw readiness:

```text
mailbox readable
subscription readable
poller woke up
sink maybe writable
store maybe ready
```

A representative active completion event:

```lua
{
  kind       = "active_job_done",
  generation = generation,
  job_id     = job_id,
  phase      = "stage",
  token      = active_token,

  status = "ok", -- or "failed" / "cancelled"
  report = report,

  result  = result_table, -- when status == "ok"
  primary = primary,      -- when status ~= "ok"
}
```

Every asynchronous completion should carry enough identity to be stale-safe.

---

## 13. Ready-event ordering

`named_choice`, `choice`, and `first_ready` select readiness. They are not priority mechanisms.

This is normally acceptable. Most update event handling should be correct without ordered choice.

Prefer making event handling:

```text
idempotent
stale-safe
generation-checked
identity-checked
retry-safe
convergent over repeated loop turns
```

Examples where unordered readiness is usually fine:

```text
two independent manager list/get requests
a model publication and a later model publication
component observer update and a periodic reconcile tick
a stale completion and an unrelated new request
duplicate progress update and later completion
publication work and a state change that will cause a later publication
```

Do not add priority machinery simply to make behaviour look deterministic. Tests should usually assert final state, ownership, and safety properties, not incidental branch order.

Explicit ready-event ordering is needed only where handling a lower-priority ready event first could make another ready event unsafe, invalid, lossy, or observably wrong.

Examples:

```text
a generation-close event must prevent admission into the old generation
an active completion must be accounted before an active slot is re-used
an ingest commit or abort must prevent further append admission for the same ingest
a stored outcome must be observed before routing a stale-sensitive reply
a control lane must be handled before a bulk lane can safely make progress
```

The rule is:

```text
Use unordered choice by default.
Make reducers idempotent and stale-safe.
Use explicit ready-event priority only at safety boundaries.
When priority is needed, use devicecode/support/priority_event.lua.
Do not roll your own priority event loop.
```

The new `job_runtime` and `active_runtime` split should reduce the need for priority. Many former ordering concerns should now be handled by ownership boundaries instead.

---

## 14. `priority_event`

`devicecode/support/priority_event.lua` is the approved helper for deterministic semantic event selection in the few places where readiness order is not enough.

It preserves the core `fibers` contract:

```text
choice combinators wake the coordinator
the priority selector chooses the semantic event
```

The helper works by running a non-yielding selector before blocking, then using an ordinary unordered wait only as a wake-up source, then running the selector again before the coordinator commits to an event.

The key shape is:

```lua
local priority_event = require 'devicecode.support.priority_event'

local function next_event_op(state)
  return priority_event.next_op {
    label = 'update.generation.next_event',

    select_now = function()
      return try_safety_event_now(state)
    end,

    wait_op = function()
      return unordered_event_wait_op(state)
    end,

    store_wake = function(...)
      store_wake_event(state, ...)
    end,
  }
end
```

Contract:

```text
select_now must not yield
store_wake must not yield
wait_op returns an Op
wait_op may use ordinary named_choice/choice
the wake result is treated as a wake-up, not automatically as the event to reduce
after waking, select_now is run again
```

The convenience helper `priority_event.sources_op` may be used for queue-like event sources where all relevant sources are intentionally checked in array order.

Use `sources_op` for small, explicit safety-priority sets. Do not use it to impose arbitrary order on a whole service merely for neatness.

---

## 15. Applying priority in Update

Most update coordinators should use ordinary unordered event selection.

Use `priority_event` only where safety depends on consuming one ready event before another.

Good Update uses include:

```text
generation close before generation-local request admission
active completion before active slot re-use
ingest terminal event before append admission
stored completion before stale-sensitive routing
sink abort/commit before further sink operations
```

A generation coordinator might split event handling like this:

```lua
local function try_safety_event_now(state)
  return try_generation_closed_now(state)
      or try_active_completion_now(state)
      or try_ingest_terminal_now(state)
end

local function unordered_event_wait_op(state)
  return fibers.named_choice {
    manager  = state.manager_rx:recv_op():wrap(map_manager_request),
    ingest   = state.ingest_rx:recv_op():wrap(map_ingest_request),
    active   = state.active_done_rx:recv_op():wrap(map_active_done),
    observer = state.observer:changed_op(state.observer_seen):wrap(map_observer_changed),
    bundled  = state.bundled_done_rx:recv_op():wrap(map_bundled_done),
  }
end

local function next_event_op(state)
  return priority_event.next_op {
    label      = 'update.generation.next_event',
    select_now = function()
      return try_safety_event_now(state)
    end,
    wait_op = function()
      return unordered_event_wait_op(state)
    end,
    store_wake = function(name, ev)
      if ev ~= nil then
        state.pending[name] = ev
      end
    end,
  }
end
```

The priority selector should be short and explicit. It should normally check only the sources whose ordering matters.

Everything else should remain unordered, idempotent, and stale-safe.

---

## 16. Job runtime

`job_runtime` owns durable job truth.

It owns:

```text
job repository loading
job repository saving
durable transition admission
durable transition serialisation
restart adoption
job deletion
job model snapshots
durable diagnostics
```

It should expose operation-shaped APIs such as:

```lua
local h = assert(job_runtime:admit_transition(spec))
local result = fibers.perform(h:outcome_op())
job_runtime:get_job_op(job_id)
job_runtime:list_jobs_op(filter)
job_runtime:changed_op(seen)
```

Internally, it may use a strict coordinator, worker scopes, and stored completions.

The outside world should not need to know whether a transition was implemented as:

```text
pure in-memory validation
control-store write
atomic replace
multi-step migration
adoption repair
delete plus save
```

That is the job runtime’s responsibility.

Job runtime failure is service failure unless the service has an explicitly designed degraded mode.

A degraded mode must be deliberate and observable, for example:

```text
update service read-only
new update jobs rejected
active adoption disabled
publisher marks update degraded
```

It must not be an accidental failure to persist.

---

## 17. Job repository

The job repository is not just a Lua table. It represents durable update state.

Separate:

```text
job repository model
  pure serialisation, normalisation, sorting, and transition helpers

job store capability adapter
  control-store calls exposed as operation-shaped APIs

job runtime
  scoped load, save, delete, transition, and adoption ownership
```

The generation coordinator may cache job snapshots and update models from job runtime observations. It should not block to save jobs inline.

If a manager request requires durability before replying, the request scope waits for a job runtime transition result.

Example rule:

```text
reply "created" only after the create-job transition has been durably persisted
```

A store failure is not a dropped log. It is a transition completion with failure status and must be applied by policy.

---

## 18. Job lifecycle

The update model may use statuses such as:

```text
created
staging
awaiting_commit
committing
awaiting_return
succeeded
failed
cancelled
timed_out
superseded
discarded
```

The exact vocabulary is product policy, but transitions must be owned by `job_runtime`.

Workers return facts:

```text
stage succeeded
stage failed
commit command accepted
commit failed before acceptance
reconcile observed success
reconcile timed out
artifact preflight failed
```

`job_runtime` applies those facts to durable job state if still current.

The generation coordinator may request transitions, observe transition completions, and update generation-local policy. It must not directly mutate durable job state.

---

## 19. Manager request scopes

Every caller-visible request that may outlive a coordinator branch should have a request scope.

This includes at least:

```text
create-job
start-job
commit-job
retry-job when it persists or starts work
cancel-job when it owns request-level policy
discard-job when it deletes artifacts or durable state
ingest create
ingest append
ingest commit
ingest abort
```

The request scope owns:

```text
request_owner
timeout policy, where applicable
blocking validation
artifact resolution
durable transition submission
caller reply or failure
```

The coordinator should not store raw bus request objects in routing tables. Store request identities and scoped-work handles where needed.

A request owner finaliser must resolve an unresolved request with a meaningful reason, for example:

```text
cancelled
terminated
generation_closed
service_shutting_down
timeout
```

Once a durable transition has been admitted by job_runtime, request cancellation does not cancel the durable transition. It only affects whether and how the caller is still waiting for the result.

---

## 20. Create-job

`create-job` is a scoped operation.

It may involve:

```text
validate component and request payload
resolve artifact source
import path into artifact store
open or reference existing artifact
inspect image metadata
verify signatures
run preflight policy
submit durable create transition
wait for persisted result
possibly request auto-start
```

Ownership rule:

```text
before job is durably saved:
  create-job scope owns newly imported artifact cleanup

after successful durable save:
  durable job record owns the artifact reference

if creation fails before ownership transfer:
  create-job finaliser releases imported artifacts
```

A successful create-job transition should carry:

```lua
{
  job_id = job_id,
  job    = public_or_internal_job_snapshot,
  auto_start = true_or_false,
}
```

If auto-start is requested, it should be a separate admission decision. Do not blur durable create with active execution.

---

## 21. Active runtime

The service should normally run one active update at a time.

The active slot is owned by `active_runtime`, not by the generation coordinator and not by the request scope.

The active slot is not a durable state store. It is execution authority.

The active runtime owns:

```text
active slot state
active token generation
active work admission
active work handle
active completion storage
active slot release
active progress model where needed
```

It does not own:

```text
durable job mutation
artifact ownership after durable save
manager request ownership
generation policy
```

The active runtime may reject admission immediately if the slot is occupied.

It may only start active work after `job_runtime` has persisted active intent.

This gives a stable active sequence:

```text
request asks to start or commit
job_runtime persists active intent
active_runtime admits execution
active worker runs
active completion is stored
job_runtime applies completion
active_runtime releases slot
```

---

## 22. Active slot lease

The active slot lease is an immediate authority granted by `active_runtime`.

It should have identity, for example:

```lua
{
  job_id = job_id,
  phase  = "stage",
  token  = active_token,
}
```

A completion must carry the same identity.

Slot release must be driven by stored active completion, not by a reporter’s continued health.

If a request obtains a durable active intent but active_runtime admission fails, policy must be explicit:

```text
mark job failed
retry admission
leave job in recoverable state
cancel active intent through job_runtime
fail service
```

It must not silently drop the durable active intent.

This is a safety boundary.

---

## 23. Start-job

`start-job` admits a job into an active stage scope.

Flow:

```text
manager endpoint receives start-job
generation coordinator validates cheap current-state facts
request scope submits durable start/staging transition to job_runtime
job_runtime persists active stage intent
request scope asks active_runtime to admit execution
active_runtime grants slot and starts active stage work
request owner replies accepted
active job completion later submits facts to job_runtime
job_runtime updates durable state
active_runtime releases slot from stored completion
```

Starting a job should not mean the coordinator performs the stage work.

The active stage scope owns:

```text
artifact opening
backend prepare
backend stage
stage timeout or cancellation
stage resource cleanup
stage result diagnostics
```

---

## 24. Commit-job

`commit-job` admits a job into active commit work.

Flow:

```text
manager endpoint receives commit-job
generation coordinator validates cheap current-state facts
request scope submits durable commit/committing transition to job_runtime
job_runtime persists active commit intent
request scope asks active_runtime to admit execution
active_runtime grants slot and starts active commit work
request owner replies accepted
commit completion later submits facts to job_runtime
job_runtime moves job to awaiting_return or failed
reconcile work is started by policy
```

Commit must be treated as an ownership and durability decision.

Once commit has been accepted by the backend or device, restart adoption rules must account for it.

---

## 25. Active job work

Active job work should use `scoped_work.start`.

Representative identity:

```lua
{
  kind       = "active_job_done",
  generation = generation,
  job_id     = job_id,
  phase      = "stage", -- or "commit" / "reconcile"
  token      = active_token,
}
```

The active job worker returns one result table:

```lua
return {
  tag = "staged",
  staged = staged_info,
  pre_commit_boot_id = boot_id,
}
```

or:

```lua
return {
  tag = "commit_started",
  commit_id = commit_id,
}
```

or:

```lua
return {
  tag = "reconciled_success",
  observed = component_snapshot,
}
```

Failures and cancellations are scope outcomes, not ad hoc return variants.

The active runtime receives the completion and decides:

```text
store completion
release or hold active slot according to policy
report facts to job_runtime
ignore stale result
fail active runtime if completion reporting is impossible
```

`job_runtime` decides durable job state.

---

## 26. Stage phase

Stage phase may perform:

```text
artifact open/read/describe
backend prepare
component preflight
backend stage
progress observation
artifact release policy
```

This belongs in the active stage scope or child operation scopes.

The stage worker may use:

```lua
local prepared = fibers.perform(backend:prepare_op(job, ctx))
local staged   = fibers.perform(backend:stage_op(job, prepared))
```

The coordinator must not call these operations inline.

Stage result should not directly mutate job tables. It should report facts.

---

## 27. Commit phase

Commit phase may perform:

```text
backend commit
device control call
record pre/post commit identity
trigger reboot or handoff
```

The commit worker reports whether the commit command was accepted, failed, or was cancelled before acceptance.

If commit acceptance means the device may reboot independently, the job must move to a durable awaiting-return state before the service loses control.

This is a durable-state rule, not a logging rule.

---

## 28. Reconcile phase

Reconcile is worker code and may block.

It should wait on:

```text
component observer changed
deadline expired
generation or active scope cancellation
```

Own-scope cancellation exits through `fibers.perform`.

Example shape:

```lua
while true do
  local which, a, b = fibers.perform(fibers.named_choice{
    changed = observer:changed_op(seen),
    timeout = sleep.sleep_until_op(deadline),
  })

  if which == "timeout" then
    return { tag = "reconcile_timeout" }
  end

  seen = a
  local snapshot = b

  local result = backend:evaluate_reconcile(job, snapshot)
  if result.done then
    return result
  end
end
```

This is acceptable because the reconcile scope is a worker lifetime, not a strict coordinator branch.

---

## 29. Backend and HAL operations

Backends should be operation-shaped.

Prefer:

```lua
backend:prepare_op(job, ctx)
backend:stage_op(job, ctx)
backend:commit_op(job, ctx)
```

Avoid synchronous methods that hide bus, HAL, or store calls:

```lua
backend:prepare(job)
backend:stage(job)
backend:commit(job)
```

Backend adapters may wrap:

```text
device service calls
HAL control calls
artifact-store calls
swupdate invocations
signature verification
image inspection
```

Each blocking operation should either expose an Op or be run inside a scoped operation that reports completion.

The coordinator decides HAL work is needed. It does not perform HAL work.

---

## 30. Artifact ownership

Artifact ownership is one of the service’s highest-risk areas.

Use explicit ownership states:

```text
external source
  caller/path/bundled package owns source

imported temporary artifact
  create-job or probe scope owns cleanup

durable job artifact
  job record owns artifact reference

active stage artifact
  active stage scope may temporarily open/read it

released artifact
  release operation has deleted/detached it
```

Rules:

```text
imported artifact is cleaned up if create-job fails before durable save
durable job owns artifact ref after save
active worker may borrow or open artifact but does not silently own deletion
artifact release is a scoped operation when it may block
finalisers release only resources they own immediately
```

If artifact deletion may block, finalisers should mark or enqueue release intent, not perform the blocking delete inline.

---

## 31. Artifact resolution and preflight

Artifact resolution should be scoped.

It may include:

```text
path import
existing ref lookup
bundled artifact discovery
metadata merge
component compatibility check
image inspection
signature verification
size/hash validation
```

Split:

```text
artifact resolver
  pure policy: source kind, component policy, metadata rules

artifact store adapter
  operation-shaped calls to artifact store

artifact preflight
  scoped validation and verification

artifact lifetime helper
  resource ownership and handoff
```

Preflight failure should produce a normal failed completion with diagnostics, and must release any resources still owned by the preflight or create scope.

---

## 32. Artifact ingest

Ingest is a separate lifetime from job creation.

An ingest instance scope owns:

```text
sink handle
bytes received
temporary artifact state
terminate-on-finalise owner
commit result
ingest model state
```

Ingest requests should be scoped when they may block:

```text
create sink
append chunk
commit sink
abort sink
```

Flow:

```text
ingest create
  starts ingest instance scope
  creates artifact sink
  replies with ingest_id

ingest append
  writes chunk through sink operation
  updates ingest model

ingest commit
  commits sink
  transfers artifact ref to caller/job creation path
  closes ingest instance

ingest abort
  aborts sink
  closes ingest instance
```

If append is slow, waiting for sink capacity belongs in the append request scope, not the coordinator branch.

If an ingest instance scope terminates while the sink is still open, its finaliser must call the sink's immediate terminate(reason) path.

An ingest terminal event is a safety-boundary event:

```text
commit or abort must close the ingest owner before further append admission for that ingest id
```

This should use `priority_event`. It should not rely on table order or a bespoke “check this first” loop.

---

## 33. Bundled reconcile

Bundled reconcile is policy, not mechanism.

It observes:

```text
cfg/update bundled policy
component observer state
job_runtime job snapshots
active_runtime slot state
manual job success/failure
desired bundled artifact identity
probe completions
```

It decides:

```text
satisfied
diverged
held
unavailable
probe needed
create job
start job
commit job
wait
```

It must not perform artifact probing inline.

Use a bundled coordinator under the generation scope:

```text
bundled coordinator
  owns per-component desired/current policy
  starts bundled probe scoped work
  starts manager-style job work when policy says so
  updates bundled model
```

Bundled probe is scoped work:

```text
open bundled source
inspect image
verify if required
produce desired identity
release temporary resources
```

Probe completion is reported as a semantic event:

```lua
{
  kind       = "bundled_probe_done",
  generation = generation,
  component  = component,
  status     = st,
  result     = desired,
  primary    = primary,
}
```

Bundled handling should normally be idempotent and stale-safe. It should not require strict event ordering except where it crosses admission or generation boundaries.

---

## 34. Component observation

Component state should be observed through a generation-owned observer model.

The observer owns:

```text
retained watches or bus subscriptions
latest component snapshots
version counter
changed_op(version)
close reason
```

It should expose:

```lua
observer:snapshot()
observer:version()
observer:changed_op(seen)
observer:terminate(reason)
```

It should not decide update policy.

The update coordinator, bundled coordinator, or active job worker consumes observer snapshots and applies policy.

Most observer updates should be safe under unordered choice. If several observer changes arrive before the coordinator handles them, the model should converge on the latest snapshot.

---

## 35. Models

Update should expose pulse-backed models.

Candidate models:

```text
service model
  readiness, generation, degraded state

job_runtime model
  durable jobs by id, transition status, adoption state

active_runtime model
  active slot, active phase, progress

component update model
  per-component current/update/bundled state

ingest model
  active ingests and progress

publisher model
  retained publication status, if useful
```

Rules:

```text
snapshot returns copies
set_snapshot is non-yielding
changed_op returns versioned observations
terminate wakes observers
models do not call bus, HAL, store, or perform Ops
models signal only on material change
```

Models should make repeated or out-of-order equivalent updates harmless.

---

## 36. Publisher

Publication should be separated from policy.

The publisher owns:

```text
retained update summary
retained job records
retained active state
retained component update state
retained ingest state
cleanup of retained publications on generation/service close
```

If local bus `retain` and `unretain` are immediate and non-yielding, publisher work may be simple.

If publication may later block or become transactional, this separation lets the service convert publication into scoped work without changing update policy.

Publication failure policy must be explicit:

```text
fail service
mark degraded
retry through scoped publisher work
drop low-priority telemetry
```

Completion and public state should not be silently lost.

Publication ordering should usually be handled through model versions and idempotent retained state, not coordinator priority.

---

## 37. Local bus contract

Update may treat these local bus operations as immediate only if the same contract as Fabric holds:

```text
publish
retain
unretain
reply
fail
subscribe
unsubscribe
watch_retained
unwatch_retained
bind
unbind
```

Update should treat these as potentially blocking:

```text
call_op
call
feed recv_op
endpoint recv_op
subscription recv_op
retained watch recv_op
```

Coordinator and finaliser use of local-bus cleanup should go through wrappers with names that document the immediate local-bus assumption.

If the bus becomes remote, transactional, or capable of suspension, these paths must be reviewed.

---

## 38. Request ownership

Use `request_owner` for caller-visible requests.

A request owner:

```text
resolves once
fails once
is finalised by the owning scope
is not stored as coordinator-owned mutable state unless wrapped by identity
```

A coordinator may immediately reject a request:

```text
no such job
wrong state
active slot busy
generation closed
invalid argument
permission denied
```

Once admitted to scoped work, the request scope owns the eventual reply.

Once a durable transition is admitted by `job_runtime`, request cancellation does not erase that admitted durable work.

---

## 39. Stored completions

Scoped work must store completion before reporting it.

This matters for:

```text
manager requests
job_runtime transitions
active job work
artifact operations
ingest operations
bundled probes
publisher failures
```

If the reporter scope is cancelled before reporting, the stored completion must remain accounted for.

The coordinator should handle stale completions safely:

```text
wrong generation -> ignore or account
unknown job id -> ignore or diagnostic
job no longer in expected phase -> ignore or diagnostic
active token mismatch -> ignore
ingest id no longer open -> ignore or diagnostic
```

Stale completion must not corrupt current state.

Stale-safety is the preferred answer to most unordered-choice concerns.

---

## 40. Finalisers

Update finalisers must be bounded and non-yielding.

Allowed:

```text
close models
detach subscriptions
release in-memory leases
terminate local sink handle through immediate terminate(reason) path
mark request owner failed
cancel child scopes without waiting
remove local records
call immediate bus cleanup helpers
```

Not allowed:

```text
perform
perform_raw
sleep
join
close_op
bus call
HAL call
artifact store blocking delete
control-store save
retry loop
protocol handshake
```

If shutdown requires waiting, model it as explicit scoped shutdown work before finalisation.

A resource that only exposes `close_op` is not suitable for finaliser-only ownership unless its adapter also exposes immediate `terminate(reason)`.

---

## 41. Ownership transfer

Ownership transfer must be explicit.

```text
before admission:
  caller/request/coordinator-side code owns cleanup

after successful admission:
  admitted scope or durable owner owns cleanup

if admission fails:
  original owner still cleans up
```

Important transfer points:

```text
imported artifact -> durable job record
artifact sink -> committed artifact ref
active intent -> active_runtime execution authority
active slot lease -> active job scope
request object -> request_owner scope
component observer watch -> generation observer
publication retained key -> publisher
```

Resource handoff must install receiver cleanup before disabling sender cleanup.

A scoped operation must not return a resource that its own finaliser will immediately close during child finalisation.

---

## 42. Restart and adoption

Restart adoption is meaningful scoped work owned by `job_runtime`.

Job runtime startup should:

```text
load persisted jobs
identify jobs requiring adoption
mark impossible states failed where policy says so
restart reconcile for awaiting_return jobs where policy says so
leave awaiting_commit jobs committable where policy says so
publish adopted state
```

Adoption should produce diagnostics.

Do not mix adoption, publication, and ordinary request handling in one startup branch without a scoped boundary.

Restart rules should be stable and tested.

Ordering during adoption should mostly be handled by job_runtime readiness and generation gating:

```text
ordinary request admission starts only once job_runtime has made adoption decisions durable or explicit
```

---

## 43. Backpressure

Backpressure policy must be explicit.

Distinguish:

```text
reject manager request
reject ingest append
slow an ingest worker
drop low-priority progress
fail active job
fail generation
fail job_runtime
mark service degraded
retry publisher/store work
```

Coordinator branches should use immediate admission helpers.

If waiting for capacity is the policy, that wait belongs in:

```text
request scope
ingest worker
publisher worker
I/O owner
scoped operation
job_runtime worker
```

Completion events should not be silently dropped while the observing scope is healthy. Store the completion, fail the observer, or apply an explicit degradation policy.

---

## 44. Suggested module structure

Target structure:

```text
src/services/
  support/
    scoped_work.lua
    queue.lua
    priority_event.lua
    resource.lua
    request_owner.lua
    bus_cleanup.lua

  update.lua

  update/
    service.lua
    generation.lua
    events.lua
    model.lua
    projection.lua
    publisher.lua

    job_runtime.lua
    job_transitions.lua
    job_repository.lua
    job_store_cap.lua
    adoption.lua

    manager.lua
    manager_requests.lua

    active_runtime.lua
    active_job.lua

    observe.lua
    bundled.lua
    bundled_probe.lua

    ingest.lua
    ingest_requests.lua

    artifacts/
      resolver.lua
      store_cap.lua
      sources.lua
      preflight.lua
      lifetime.lua

    backends/
      component_proxy.lua
      cm5_swupdate.lua
      mcu_component.lua
      reconcile.lua

    topics.lua
    crypto.lua
    config.lua
```

Roles:

```text
support/priority_event.lua
  the only approved helper for deterministic ready-event priority
  used only at safety boundaries

update.lua
  public entry point

service.lua
  top-level coordinator, job_runtime supervision, generation lifecycle, capability publication

generation.lua
  config generation lifecycle and generation-local ownership

events.lua
  semantic event construction
  ordinary unordered wait construction
  safety-priority selection through support/priority_event.lua

model.lua
  internal pulse-backed model state

projection.lua
  pure conversion to public retained payloads

publisher.lua
  retained publication owner

job_runtime.lua
  durable job authority, transition admission, adoption, job model

job_transitions.lua
  pure transition validation and state transformation

job_repository.lua
  pure durable job serialisation and transition helpers

job_store_cap.lua
  operation-shaped control-store adapter

adoption.lua
  restart/adoption policy and scoped adoption work

manager.lua
  endpoint binding and request admission

manager_requests.lua
  scoped implementations of manager commands

active_runtime.lua
  active slot, active intent execution admission, active completion storage

active_job.lua
  stage, commit, and reconcile worker bodies

observe.lua
  component observer model

bundled.lua
  bundled policy coordinator

bundled_probe.lua
  scoped desired-artifact probing

ingest.lua
  ingest coordinator and ingest model

ingest_requests.lua
  scoped ingest create/append/commit/abort implementations

artifacts/*
  artifact source resolution, store calls, preflight, ownership helpers

backends/*
  component-specific update backends with *_op calls

topics.lua
  pure topic construction

crypto.lua
  signature verifier policy and adapter

config.lua
  pure config validation and normalisation
```

One file per semantic owner, not one file per small helper.

---

## 45. Test focus

Update tests should cover losing paths, cancellation paths, stale paths, ownership paths, durability paths, and safety-priority paths.

Critical tests:

```text
update service code does not use perform_raw
strict coordinators do not call join_op directly
strict coordinators do not call HAL/backend/store/artifact calls inline
coordinator event handling is idempotent where ordering should not matter

job_runtime is the only durable job mutation authority
generation cached job snapshots are not treated as authority
manager request scopes submit transitions rather than saving jobs directly
active_runtime does not mutate durable job state
active workers report facts rather than patching jobs

transition rejected before admission has no durable effect
transition failed after admission is accounted for by job_runtime
caller cancellation after transition admission does not lose the admitted transition
job_runtime failure is surfaced as service failure or explicit degraded mode

active work does not start before durable active intent exists
active intent persisted before active_runtime execution admission
active completion is stored before reporting to job_runtime
active slot is released from stored active completion
active token mismatch is stale and does not corrupt state

priority-sensitive coordinators use support/priority_event.lua
no bespoke priority event loops exist in update code
priority_event select_now functions do not yield
priority_event store_wake functions do not yield
priority_event is used only at safety boundaries

after wake, safety-priority events are rechecked before committing to lower-priority events
active completion and new start both ready cannot double-own the active slot
generation close and generation-local admission both ready cannot admit into closed generation
ingest terminal event and append both ready cannot append after terminal state

manager request owner fails unresolved request on scope cancellation
create-job imported artifact is cleaned up if save fails
create-job imported artifact is not cleaned after durable job owns it
start-job grants active execution authority exactly once
second active job is rejected without blocking
stale active job completion is ignored

commit-job cancellation cancels commit/reconcile work by parentage
awaiting_return job is adopted on restart
awaiting_commit job remains committable on restart, if policy says so
component observer stale-generation events are ignored
reconcile timeout produces the expected durable state

bundled probe runs in scoped work
bundled coordinator does not block while probing
bundled policy is stale-safe under unordered events
manual success/failure affects bundled policy as specified

ingest sink is terminated by finaliser if scope ends while open
ingest append after commit or abort is rejected
ingest append failure resolves request exactly once
ingest commit transfers artifact ownership exactly once
ingest abort closes model and sink exactly once

publisher only signals material changes
publisher retained cleanup uses immediate wrappers
publication failure policy is explicit

finalisers do not hide suspension: no sleep, join, close_op, blocking calls, or readiness waits
resource handoff installs receiver cleanup before sender cleanup is disabled
job-store failure is surfaced as completion, not swallowed
HAL reply paths are abandonment-safe
```

A useful ordering test should prove safety, not arbitrary order.

Good:

```text
if active completion and new start are both ready, the slot cannot be double-owned
```

Poor:

```text
branch A always runs before branch B
```

---

## 46. Example flows

### Create-job

```text
manager request received
  -> coordinator admits request scope
  -> request scope validates payload
  -> request scope resolves/imports/preflights artifact
  -> request scope submits durable create transition to job_runtime
  -> job_runtime persists job
  -> request scope replies from transition result
  -> publisher projects job_runtime model
```

Ownership:

```text
artifact temporary cleanup belongs to create-job scope until durable save
artifact reference belongs to durable job record after successful save
request reply belongs to request scope
durable state belongs to job_runtime
```

### Start-job

```text
manager request received
  -> coordinator admits request scope
  -> request scope submits durable active-intent transition to job_runtime
  -> job_runtime persists staging intent
  -> active_runtime receives authority to execute
  -> active_runtime starts active stage scope
  -> request scope replies accepted
  -> active worker reports stage facts
  -> active_runtime stores completion
  -> job_runtime applies completion to durable state
  -> active_runtime releases active slot
  -> publisher projects job_runtime and active_runtime models
```

Ownership:

```text
durable active intent belongs to job_runtime
active execution belongs to active_runtime
stage resources belong to active job scope
request reply belongs to request scope
```

### Commit-job

```text
manager request received
  -> request scope submits durable commit intent
  -> job_runtime persists committing intent
  -> active_runtime starts commit scope
  -> request scope replies accepted
  -> commit worker reports commit accepted or failed
  -> job_runtime persists awaiting_return or failed
  -> reconcile scope starts if policy says so
  -> reconcile reports final facts
  -> job_runtime persists succeeded, failed, or timed_out
```

Ownership:

```text
commit durability belongs to job_runtime
commit execution belongs to active_runtime
reconcile execution belongs to active_runtime or a child scope under it
restart adoption belongs to job_runtime
```

---

## 47. Compact rules

```text
Ops describe what may wake a fibre.
Scopes describe what owns a lifetime.
fibers.perform waits under the current scope.
perform_raw is infrastructure.

The update coordinator decides policy.
The generation owns config-local state.
The job_runtime owns durable job truth.
The active_runtime owns active execution.
Manager request scopes own caller-visible requests.
Active job scopes own stage, commit, and reconcile work.
Ingest scopes own sink handles.
Artifact scopes own temporary artifact cleanup.
Backend/HAL operation scopes own blocking calls.
Publisher owns retained publication.
Models expose observations.

Durability is not a side effect of requests.
Durability is a runtime with authority.
Requests may wait for durable results.
Requests do not own admitted durable mutation.

Active work starts only after durable active intent exists.
Workers report facts.
Job runtime applies facts.
Active runtime releases active slot from stored completion.

A coordinator blocks only at its control point.
A coordinator branch must not suspend.
A coordinator waits on semantic events, not raw readiness.

Combinators select readiness, not priority.
That is fine by default.
Use idempotence and stale checks first.
Use explicit ready-event priority only where safety or externally visible correctness depends on it.
Where priority is needed, use support/priority_event.lua.
Do not roll your own priority event selector.

Use immediate helpers for admission.
Immediate means no readiness wait, not cancellation atomicity.

Use scoped_work.start for child work.
Parentage owns cleanup.
Early reaping must be explicit.
Reporters do not join.
Store completion before reporting it.
Ignore stale completions.

Use request_owner for caller-visible requests.
Use finalisers for owned cleanup.
Finalisers must not wait.

Make artifact ownership transfer visible.
Make durable job ownership visible.
Make active intent transfer visible.
Make active slot transfer visible.
Make ingest sink ownership visible.

HAL work is scoped work.
Artifact work is scoped work.
Bundled probing is scoped work.
Restart adoption is job_runtime scoped work.

Do not hide suspension.
Do not hide ownership.
Do not let implementation convenience decide lifetime.
```

---

## 48. Mental model

```text
Service coordinator:
  starts job_runtime
  starts generations
  publishes service capability
  observes generation and runtime completion

Generation coordinator:
  owns config-local policy
  waits for semantic events
  treats unordered events as normal where reducers are safe
  uses priority_event only at safety boundaries
  starts request scopes and policy work
  updates generation-local models

Job runtime:
  owns durable jobs
  admits and applies transitions
  performs store work in scoped workers
  owns restart adoption
  exposes job model changes

Manager request scope:
  owns the request
  performs blocking command work
  submits durable transitions
  replies or fails exactly once

Active runtime:
  owns active slot and execution authority
  starts active work only after durable active intent
  stores completion before reporting
  releases active slot from stored completion

Active job scope:
  owns stage/commit/reconcile
  performs backend/HAL Ops
  returns one result table

Ingest scope:
  owns sink lifecycle
  commits or aborts artifact creation

Artifact operation:
  owns temporary artifact resources
  transfers ownership explicitly

Bundled coordinator:
  observes desired/current state
  starts probes and jobs
  never probes inline

Publisher:
  observes models
  publishes retained public state

Finaliser:
  releases what the scope owns now
  does not wait
```

The shortest useful rule is:

```text
Update state is coordinated; durable jobs are owned by job_runtime; active work is owned by active_runtime; resources are owned by scopes.
```

And for ordering:

```text
Do not order events for neatness.
Order them only when safety requires it.
When safety requires it, use priority_event.
```


## Implementation boundary addendum

Current update code follows these concrete boundaries:

```text
job_runtime:admit_transition(cmd) is immediate and does not build or perform an Op.
The returned handle owns outcome observation through handle:outcome_op().
Runtime transition workers own actual durable persistence.
Active commit workers persist commit_accepted after backend acceptance before returning success.
If backend acceptance occurs and commit_accepted persistence then fails, the worker raises a critical inconsistent-outcome failure.
Production update code has no active_runner bypass; tests fake backends, stores, observers, and clocks instead.
Ingest commit admission is separate from commit worker execution; constructing helpers must not mutate lifecycle state.
Artifact resolver entry points are worker-only.
```
