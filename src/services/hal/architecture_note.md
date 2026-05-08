# HAL architecture note

## 1. Purpose

HAL is the compatibility and capability boundary between Devicecode services and concrete platform implementations.

It should make platform-specific behaviour available through a stable service shape while keeping the rest of the system:

```text
responsive
structured
testable
scope-owned
diagnosable
independent of driver details
```

HAL has two jobs:

```text
present stable capability contracts to services
adapt current and legacy provider implementations behind a compatibility seam
```

The design aim is that `device`, `update`, `ui`, and Fabric can depend on HAL capabilities without inheriting provider-specific lifetime, cancellation, or cleanup behaviour.

---

## 2. Core model

HAL is organised around five roles.

```text
HAL service coordinator
  Owns provider registration, capability indexes, and service-level state.
  Selects events at its control point.
  Must not suspend inside event branches.

Capability provider
  Owns one concrete capability implementation.
  Exposes operations through a stable HAL contract.
  May wrap platform, driver, or legacy implementation details.

Operation scope
  Owns one meaningful HAL operation.
  Owns cancellation, timeout, cleanup, diagnostics, and completion.
  Reports completion through the standard envelope.

Compatibility adapter
  Bridges old or irregular provider APIs into the current HAL model.
  Is the only place where compatibility compromises should live.

Driver/backend
  Performs concrete work.
  May block only through Ops selected by a scoped operation or owner.
```

The central rule is:

```text
HAL coordinators decide and route; operation scopes perform and clean up.
```

---

## 3. Compatibility seam

HAL deliberately contains a compatibility seam.

The seam exists so that older or lower-level implementations can be adapted without leaking their shape into service code.

Compatibility code may translate:

```text
legacy method names
older reply shapes
driver-specific error values
backend-specific status values
different capability metadata forms
older start/stop conventions
```

Compatibility code must not weaken the service model.

It must preserve:

```text
scope-owned lifetime
bounded finalisers
standard completion shape
explicit cancellation
stale-safe identity
non-suspending coordinator branches
stable capability contracts
```

The compatibility seam should be narrow and named. It should normally live in adapter modules or provider wrappers, not in service coordinators.

A useful rule is:

```text
Compatibility belongs at the edge. HAL semantics belong in the middle.
```

---

## 4. Coordinator rule

A strict HAL coordinator has one suspending point: its control point.

```lua
while true do
  local ev = fibers.perform(next_hal_event_op(state, scope))

  if ev.kind == "stop" then
    return
  end

  local decision = reduce_event(state, ev)
  dispatch_effects_nonblocking(state, decision.effects)
end
```

After event selection, the coordinator must not suspend before returning to the control point.

Not allowed in coordinator branches:

```lua
fibers.perform(provider:operation_op(...))
fibers.perform(scope:join_op())
fibers.perform(tx:send_op(...)) -- if it can block
fibers.perform(rx:recv_op(...))
sleep.sleep(...)
scope:join(...)
```

Allowed in coordinator branches:

```text
mutate coordinator-owned indexes
record pending operations
create a child scope
spawn operation work into a child scope
cancel a child scope
ignore stale completions
publish through APIs documented as immediate
make an or_else-backed immediate admission attempt
reply or fail an immediate in-memory request object
```

The important constraint is suspension. A coordinator may use a helper documented as non-yielding, including an `or_else`-backed immediate admission helper.

---

## 5. Capability contracts

A HAL capability contract should describe:

```text
capability class and id
supported verbs
request argument shape
reply shape
error shape
operation lifetime
cancellation behaviour
cleanup ownership
diagnostic fields
```

Provider-specific details should not appear in callers.

Callers should see stable capabilities such as:

```text
control operation
status publication
metadata publication
event publication
operation completion
```

Provider implementations may vary internally, but the exported HAL contract should not.

Where a provider has a legacy or irregular shape, add an adapter. Do not teach every caller about that irregularity.

---

## 6. Operation scopes

Use an operation scope when HAL work has any of the following:

```text
blocking backend calls
temporary handles
owned buffers or files
rollback or cleanup
timeout ownership
retry state
child work
diagnostic value
completion result
```

A HAL operation scope should:

```text
own the operation lifetime
register cleanup with scope:finally(...)
perform backend Ops according to local policy
return one result table on success
let unexpected errors escape to the scope
```

Example shape:

```lua
local function run_hal_operation(scope, ctx, req)
  scope:finally(function(aborted, status, primary)
    cleanup_owned_resources()
  end)

  local result = fibers.perform(ctx.backend:operation_op(req.args))

  return {
    value = result,
  }
end
```

The coordinator starts the operation scope and observes completion later as an event. It does not perform the operation inline and does not run the operation cleanup.

---

## 7. Finalisers and cleanup

HAL cleanup is finaliser-first.

If a HAL operation owns a resource, cleanup should be registered in the operation scope with `fibers.finally(...)`(preferred in the same scope) `scope:finally(...)`(finalisers can only be added to other scopes before they have started).

Finalisers must run promptly.  A finaliser may perform only an Op that is ready now.  In practice this permits explicit try-now helpers built with `or_else(...)`, and rejects hidden waits.

Allowed in finalisers:

```text
terminate immediate handles
detach local registrations
release local reservations
mark local objects closed
abandon explicitly safe-to-abandon resources
remove immediate local state
perform an explicitly ready-now Op, such as an or_else-backed try helper
```

Not allowed in finalisers:

```text
performing an Op that may wait
sleep
join
join_op
queue send that may block
request/reply protocols
normal shutdown handshakes
backend calls that may block
close_op
```

Resources owned by finalisers must provide:

```text
terminate(reason)
```

If cleanup needs protocol progress or waiting, it belongs in the operation body before completion, not in the finaliser.  Graceful cleanup belongs in `close_op()` and must be called explicitly outside finalisers.

---

## 8. Completion events

HAL scoped work should use the standard completion envelope.

```lua
{
  kind         = "hal_operation_done",
  operation_id = operation_id,
  generation   = generation,

  status = st,
  report = rep,

  result  = result_table_or_nil,
  primary = primary_error_or_reason_or_nil,
}
```

Rules:

```text
status == "ok"        -> result is present
status == "failed"    -> primary is present
status == "cancelled" -> primary is present
```

Successful operations return one result table.

```lua
return {
  reply = reply,
}
```

Coordinator completion handling must be stale-safe.

```lua
local rec = state.operations[ev.operation_id]
if not rec or rec.generation ~= ev.generation then
  return
end
```

A missing operation record is a stale completion. Stale completion is harmless and usually quiet.

---

## 9. Cancellation and timeout policy

Cancellation and timeout belong to the operation scope that owns the work.

A coordinator may cancel an operation scope, but must not join it inline.

There are two normal policies.

```text
reply_on_abandon
  The coordinator cancels the operation scope, replies immediately, clears its
  record, and treats later completion as stale.

reply_on_scope_completion
  The coordinator cancels the operation scope, keeps its record, and replies only
  when the operation completion event arrives.
```

Use `reply_on_abandon` when the caller only needs to know that HAL has abandoned the operation.

Use `reply_on_scope_completion` when the caller is promised that cleanup, rollback, or hardware state has reached a known point.

The chosen policy should be explicit in the operation record where it matters.

---

## 10. Provider lifecycle

Provider start and stop should be scope-owned.

A provider may own:

```text
backend handles
subscriptions
watchers
driver state
operation limiters
published state
```

The provider scope should install finalisers for provider-owned cleanup.

Provider start may publish initial metadata and state through APIs documented as immediate. If provider start requires blocking setup, that setup should be represented as scoped work, not hidden in a coordinator branch.

Provider stop should normally mean:

```text
cancel provider scope
let provider finalisers release owned resources
observe provider completion at the service boundary
ignore stale operation completions
```

Provider stop should not require a coordinator to synchronously join child operations.

---

## 11. Admission and backpressure

HAL must make admission policy explicit.

For bounded in-flight operations, the coordinator may reject immediately:

```text
busy
unavailable
unsupported
invalid_args
provider_stopped
```

If a bounded queue or operation lane is full, the policy must be clear:

```text
reject the request
cancel the provider
mark degraded
drop optional telemetry
start no work
```

A strict coordinator should use an immediate admission helper based on `or_else` when it needs a non-blocking handoff.

It should not block on queue capacity.

---

## 12. Error policy

Inside operation scopes, owners, and providers, ordinary unexpected errors should normally escape.

Use `pcall` only where there is local recovery policy:

```text
convert a backend negative result into a protocol reply
retry a transient operation
isolate optional or untrusted code
perform best-effort bounded cleanup
```

If catching only to log, rethrow.

Use `status` for control flow and `report` for diagnosis. Do not make ordinary service logic depend on deep report structure.

---

## 13. Module role contracts

```text
hal service coordinator
  role: provider and capability coordinator
  may suspend: service control-point event selection only
  owns: provider indexes, capability indexes, service-level state
  delegates: provider scopes and operation scopes

provider module
  role: capability implementation boundary
  owns: provider-local state and provider-owned resources
  exposes: stable capability contract
  may use: scoped operation work

compatibility adapter
  role: legacy or backend shape adapter
  owns: translation between old and current contracts
  must not own: service policy

operation module
  role: scoped work unit
  may perform: backend Ops, timeout/cancellation choice, local operation policy
  owns: one HAL operation lifetime
  cleans up: with scope:finally(...)

resource helper
  role: bounded cleanup helper
  must not call: close_op; perform on Ops that may wait
```

---

## 14. Test principles

HAL tests should cover compatibility and losing paths, not only happy paths.

Important tests:

```text
provider publishes stable capability metadata
legacy provider shapes are adapted at the seam
unsupported verbs return stable negative replies
invalid arguments return stable negative replies
busy is returned when max in-flight is reached
operation completion uses the standard envelope
operation cancellation runs finalisers
operation timeout cancels owned work
stale completions are ignored
provider stop cancels in-flight operation scopes
finalisers do not perform Ops that may wait and do not call close_op
resources are cleaned up by the scope that owns them
backend errors escape to the owning operation scope unless locally handled
```

For immediate admission helpers, test both cases:

```text
admission succeeds immediately
admission would block and returns immediately without suspension
```

For compatibility adapters, test that callers see the same public contract regardless of backend shape.

---

## 15. Review checklist

For a HAL coordinator:

```text
Is there one suspending wait at the control point?
Can any event branch suspend?
Are operation lifetimes represented as scopes?
Are child scopes cancelled but not joined inline?
Is admission immediate and explicit?
Are completions identified and stale-safe?
Are provider indexes and capability indexes coordinator-owned?
Are backend calls kept out of coordinator branches?
```

For a provider:

```text
What capability contract does it expose?
What resources does it own?
Which scope owns those resources?
What finalisers release them?
What operations may it start?
What happens when it is stopped with work in flight?
```

For an operation scope:

```text
What lifetime does this operation own?
What resources are admitted into it?
Are resources cleaned up by scope:finally(...)?
Is cleanup bounded and non-yielding?
How are timeout and cancellation handled?
What one result table is returned on success?
What failures are normal negative replies, and what failures should escape?
```

For a compatibility adapter:

```text
What legacy or backend shape is being adapted?
Is the compatibility contained at the edge?
Does the public HAL contract remain stable?
Does the adapter preserve cancellation, cleanup, and completion semantics?
Does it avoid introducing blocking work into coordinator paths?
```

---

## 16. Compact rules

```text
HAL coordinators block only at their control point.
Capability contracts are stable; compatibility lives at the edge.
Coordinators route and decide; operation scopes perform.
A fibre runs code; a scope owns lifetime.
Use scopes for HAL operations with blocking work, cleanup, timeout, or diagnostics.
Use scope:finally(...) for scope-owned cleanup.
Finalisers must be bounded and non-yielding.
Do not call close_op in finalisers.
Use standard completion envelopes.
Carry operation identity and generation on completions.
Ignore stale completions.
Use explicit admission policy for bounded in-flight work.
Use or_else-backed immediate admission where a coordinator needs non-blocking handoff.
Let unexpected errors escape to the owning scope.
Use reports for diagnosis, not ordinary control flow.
Keep compatibility seams narrow, named, and out of callers.
```

---

## 17. Short mental model

HAL is the compatibility and capability boundary.

```text
coordinator:
  indexes providers and capabilities
  admits or rejects work
  starts operation scopes
  observes completion
  does not perform backend work

provider:
  implements a stable capability contract
  hides backend details
  owns provider-local lifetime through scope

operation scope:
  owns one HAL operation
  performs backend work
  owns timeout and cancellation
  cleans up with finalisers
  reports completion

adapter:
  translates old or irregular backend shape
  preserves HAL semantics
  keeps compatibility out of callers
```

The coordinator does not ask:

```text
can I just call the backend here?
can I wait for this operation here?
can I clean this up manually later?
```

It asks:

```text
what capability is being requested?
can the work be admitted now?
which scope owns the operation?
what completion should I later accept or ignore?
```

The operation scope asks:

```text
what resources do I own?
what finalisers release them?
what timeout and cancellation policy applies?
what result or failure crosses the boundary?
```
