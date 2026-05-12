# HTTP architecture note

> **Basis of this note**
>
> This note follows the Fabric architecture doctrine.
>
> This architecture is grounded in a close reading of the current `fibers` source, especially `fibers.scope`, `fibers.performer`, `fibers.op`, and the public re-exports in `fibers.lua`.
>
> It relies on the observed runtime contracts that:
>
> * `fibers.perform` is scope-aware;
> * `fibers.spawn` spawns into the current scope;
> * `perform_raw` bypasses scope-aware cancellation and belongs to infrastructure;
> * scope cancellation is downward only;
> * scope cancellation is cooperative;
> * parentage is the structural ownership mechanism;
> * attached child scopes are cancelled when the parent is cancelled and joined by the parent’s join/finalisation path;
> * `join_op()` starts active, non-passive join/finalisation;
> * joining closes admission, waits for fibres, joins attached children, runs finalisers, records an outcome, and detaches the joined scope from its parent;
> * `join_op()` is not authority-checked by the runtime, so Fabric must enforce join authority by discipline;
> * child failure is reported through scope outcomes rather than implicitly promoted to the parent;
> * once a scope has started, its finalisers must be installed from inside that scope;
> * before a scope has started, infrastructure may install finalisers on it;
> * during finalisation, scope-aware `perform` may complete only Ops that are ready immediately, and raises if an Op would suspend;
> * `or_else()` is the standard public way to build explicit try-now Ops;
> * `run_scope_op` creates, runs, joins, and reports a child-scope boundary; if it loses a choice, its abort path cancels and joins that child scope using infrastructure-level non-interruptible cleanup;
> * `named_choice`, `choice`, and `first_ready` select readiness, not semantic priority;
> * Lua table order must not be used as a priority mechanism.
>
> If these source-level contracts change, this architecture should be reviewed.

---

## 1. Purpose

HTTP is a system capability service.

It exposes HTTP, HTTPS and WebSocket capability through the local bus, backed initially by `lua-http` and `cqueues`, while presenting a `fibers`-native API to consumers.

The service is intended for local users such as UI, update, diagnostics and Fabric support code, and for future remote use over Fabric where a smaller node can request HTTP work from a node with a full network stack.

Core rules:

```text
HTTP is a capability service, not a UI submodule.
The bus is the control plane.
Body bytes and WebSocket frames do not travel over the bus.
Local streaming uses local handles.
Remote-safe work uses descriptors and explicit data-plane references.
Every stream-like object has one clear owner.
```

The intended programming model is:

```lua
local which, chunk = fibers.perform(fibers.named_choice{
  chunk   = response:read_chunk_op(65536),
  timeout = sleep.sleep_op(2),
})
```

Public HTTP APIs should return Ops. They should not hide waits inside timeout-taking black-box calls.

Ordinary code does not race its own scope cancellation. `fibers.perform` is already scope-aware.

---

## 2. Capability surface

HTTP uses the established capability topic shape:

```text
cap/<class>/<id>/meta
cap/<class>/<id>/status
cap/<class>/<id>/state/<key>
cap/<class>/<id>/event/<name>
cap/<class>/<id>/rpc/<verb>
```

Initial instance:

```text
cap/http/main
```

Suggested RPC verbs:

```text
status
listen
open_exchange
exchange
connect_ws
```

Local-only verbs may return Lua handle objects:

```text
listen          -> HttpListener
open_exchange  -> HttpExchange
connect_ws     -> WebSocket
```

Descriptor-based verbs are remote-capable in shape:

```text
exchange
```

A descriptor-based verb is only actually remote-capable when all body source and sink descriptors are resolvable under an explicit data-plane contract.

HTTP is not HAL. HAL exposes platform/provider capabilities. HTTP exposes a higher-level protocol capability. Both may use the `cap/` grammar.

---

## 3. No byte streams over the bus

Allowed over the bus:

```text
method
URI
headers
policy
operation identity
handle metadata
status
small replies
errors
body source descriptors
response sink descriptors
completion envelopes
```

Not allowed over the bus:

```text
HTTP body chunks
file contents
WebSocket frames
long-lived iterators
hidden stream objects in serialised tables
```

Example source descriptor:

```lua
{
  kind = "blob_source",
  ref  = "..."
}
```

Example sink descriptor:

```lua
{
  kind = "blob_sink",
  ref  = "..."
}
```

Descriptor resolution is authority-bearing. It must be done through a named boundary module, with principal, origin and policy checks before a local source or sink object is returned.

Initial descriptor families may include:

```text
local_blob_source
local_blob_sink
artifact_source
artifact_sink
fabric_transfer_source
fabric_transfer_sink
```

Only descriptors with an implemented resolver and authority check are valid. Unrecognised descriptors must be rejected before backend admission.

---

## 4. Runtime discipline

HTTP follows the Fabric service doctrine.

```text
Ops describe possible waits.
Scopes own lifetimes.
fibers.perform waits under the current scope.
perform_raw is infrastructure.
Finalisers terminate owned resources immediately.
Coordinators decide what events mean.
```

HTTP service code must not use `perform_raw`.

`perform_raw` is permitted only in runtime, scheduler, low-level Op tests, or narrowly documented bridge infrastructure.

Coordinator branches must not suspend.

Allowed in coordinator branches:

```text
mutate coordinator state
record handles and operations
start scoped work
cancel child scopes
ignore stale completions
resolve immediate in-memory request owners
publish/retain through documented immediate bus helpers
use tested try-now helpers
update models
terminate owned handles immediately
```

Not allowed in coordinator branches:

```text
HTTP reads or writes
WebSocket receive or send
stream flush
bus call_op
sleep
join or join_op
perform_raw
run_scope_op for child work
blocking queue send
backend protocol handshakes
```

### Active transport cancellation

Transport Ops have three observable phases:

```text
constructed
  no backend admission has happened

queued
  the backend command is queued, but has not entered lua-http/cqueues work

active
  lua-http/cqueues work has begun and may have advanced protocol state
```

If a queued Op loses a Fibers choice or is interrupted by its owning scope, the
queued command is abandoned and must not run.

If an active Op loses, the smallest owning backend object must be terminated:

```text
active server context command       -> terminate HttpContext
active exchange response command    -> terminate HttpExchange
active WebSocket command            -> terminate WebSocket or owning context
active open/connect setup           -> terminate request/setup object where possible
no narrower safe owner              -> terminate the driver
```

The caller-facing rule is:

```text
If an HTTP/WS Op loses before backend work starts, nothing happened.
If it loses after backend work starts, the affected handle is no longer usable.
```

An active backend operation must not continue invisibly after the Fibers Op that
represents it has lost.

---

## 5. Lifetime tree

Target shape:

```text
http service scope
  service coordinator

  backend scope
    named backend component
    cqueues driver
    lua-http backend integration
    identity-bearing backend_done completion

  capability scope
    bus endpoint bindings
    retained cap metadata/status/state

  listener scopes
    listener owner
    accept queue
    unaccepted context registry

  accepted context scopes
    owned by consuming service after accept

  exchange scopes
    outgoing request/response owner
    body source and sink leases

  websocket scopes
    websocket transport owner
    reader owner
    writer owner

  operation scopes
    one-shot exchange
    open exchange setup
    connect websocket
    explicit graceful close/shutdown
```

HTTP normally has one cqueues driver per HTTP service instance. Multiple drivers should be an explicit isolation policy, not the default.

The backend pump is a named long-running component. Production drivers expose `run()` and `terminate()`, and the service starts them through scoped work with a `backend_done` completion carrying component identity and generation. Tiny `start()`-only fakes may be used in isolated tests, but that path has no meaningful pump completion and is not the production lifecycle shape.

Introduce a scope when work has:

```text
identity
owned resources
cleanup
blocking I/O
child work
caller-visible result
timeout policy
diagnostics
ownership transfer
completion reporting
```

A fibre runs code. A scope owns lifetime.

Use `fibers.spawn` for work in the current scope. Use `scope:spawn` only when deliberately spawning into a specific target scope.

Reusable service helpers should accept a `scope` argument only when they are intentionally operating on that scope's lifetime. Otherwise, prefer current-scope spawning so ownership is not made to look broader than it is.

---

## 6. Local handle lifetime rule

A local handle returned over the bus is not owned by the RPC operation after successful handoff.

The rule is:

```text
before registry admission:
  setup operation owns cleanup

after registry admission:
  HTTP service registry owns shutdown backstop responsibility

after reply to caller:
  caller owns normal use and should close or terminate when finished

during service shutdown:
  HTTP service may terminate remaining registered handles
```

All handle cleanup must be idempotent. Service shutdown, caller cancellation, backend failure and explicit close may race.

A setup operation must not return a handle that its own finaliser will immediately terminate.

The caller owns normal protocol use after handoff. The HTTP service registry owns accounting and shutdown backstop termination.

This applies to:

```text
HttpListener
HttpExchange
HttpContext
WebSocket
body source leases
body sink leases
```

---

## 7. Listener and context ownership

A listener owns:

```text
server object
accept queue
unaccepted contexts
listener status
termination of unaccepted contexts
```

Ownership transfer:

```text
before accept:
  listener owns accepted context cleanup

successful accept:
  caller/request scope owns the context

after successful accept:
  listener may retain stale-safe accounting only

listener termination:
  listener terminates only contexts still owned by the listener
```

`HttpContext:terminate(reason)` must be immediate, idempotent, non-yielding and finaliser-safe.

Graceful response work belongs in a request scope, not in listener cleanup.

Closing a listener stops further accepts and terminates listener-owned unaccepted contexts. It does not terminate contexts already transferred to caller scopes.

HTTP service shutdown or backend failure may terminate all contexts as a last-resort backstop.

### Server-side response ownership

Once a context is accepted:

```text
the consuming request scope owns response resolution and graceful response work
the HttpContext object owns immediate transport termination
unresolved response finalisation belongs to the consuming request scope
unresolved response finalisation does not belong to the HTTP service coordinator
```

---

## 8. Outgoing exchange ownership

For `open_exchange`:

```text
setup operation creates exchange
setup operation owns cleanup until registry admission
service registry records exchange before reply
reply returns local handle
caller performs exchange Ops
service finaliser terminates live registered exchanges
```

For one-shot `exchange`:

```text
operation scope owns exchange
operation scope owns body source and sink leases
operation finaliser terminates unfinished resources
successful result is metadata only
```

One-shot exchange shape:

```text
validate request
check policy
open exchange
install termination finaliser
resolve body source/sink descriptors
install source/sink cleanup before first wait
copy request body
finish request
read response headers
copy response body
finish or commit sink
detach committed sink cleanup where contract requires
return one result table
```

Committed sink or artefact ownership is not reclaimed by HTTP unless the sink provider contract explicitly delegates that cleanup back to HTTP.

---

## 9. WebSocket ownership

A WebSocket handle exposes:

```text
receive_op()
send_op(...)
send_ping_op(...)
send_pong_op(...)
close_op(...)
terminate(reason)
stats()
```

Rules:

```text
reader scope owns receive
writer scope owns send
application service owns routing/session semantics
close_op is graceful and may wait
terminate(reason) is immediate and finaliser-safe
WebSocket frames do not travel over the bus
```

Future remote WebSocket use needs an explicit frame data plane or higher-level protocol. It must not be hidden as bus-per-frame RPC.

---

## 10. Backend boundary

`lua-http` owns:

```text
HTTP parsing
HTTP/1.1 and HTTP/2 protocol state
TLS integration
WebSocket handshake mechanics
stream coroutine affinity
```

HTTP service owns:

```text
Fibers-facing Ops
scope ownership
resource termination
capability surface
security and egress policy
handle registry
body source/sink policy
completion reporting
```

No module outside `services/http/transport` should require `cqueues` or `lua-http` directly.

After UI migration, no `services/ui` module should require `services/http/transport` directly.

---

## 11. cqueues bridge

The cqueues bridge is infrastructure.

It owns:

```text
cqueues controller
pollable readiness integration
run_op job queue
controller pump
immediate termination
```

It may know about:

```text
pollfd()
events()
timeout()
step(0)
cqueues controller wrapping
cqueues coroutine jobs
```

Higher HTTP modules should not.

Callbacks must not call service reducers, mutate coordinator state directly, or perform Fibers operations.

Callbacks may only:

```text
update backend-local state
wake the bridge
admit backend-local objects through an Op-facing boundary
```

Bridge properties:

```text
readiness is a hint, not a result
losing run_op aborts before execution where possible
termination wakes pending jobs
multiple run_ops share one pump
spurious readiness is non-fatal
```

---

## 12. Public handle API

The backend wrapper should expose Fibers-native objects:

```text
HttpListener
HttpContext
HttpExchange
WebSocket
```

Typical Ops:

```text
listen_op
accept_op
read_chunk_op
write_chunk_op
response_headers_op
close_op
connect_op
receive_op
send_op
```

Public service-facing APIs should prefer composable Ops. Backend timeout arguments may exist at the edge for compatibility, but timeout policy should normally be expressed by the caller with `sleep.sleep_op(...)`.

Service-owned one-shot operations may still enforce configured maximum durations. That timeout is service policy, not hidden caller policy.

---

## 13. Body sources and sinks

Body copying belongs in operation scopes.

A source provides:

```text
read_chunk_op(max)
terminate(reason)
```

A sink provides:

```text
write_chunk_op(chunk)
finish_op()
terminate(reason)
```

Rules:

```text
normalise descriptors before work starts
install cleanup before the first cancellable wait
enforce byte limits during copying
use terminate(reason) in finalisers
use finish_op()/close_op() only in explicit scoped work
reject raw chunks or iterators in bus payloads
```

---

## 14. Request owners and completions

Capability RPC requests are caller-visible request lifetimes.

A request owner lives in the scope that owns the request. It must:

```text
reply at most once
fail at most once
finalise unresolved requests from its owning finaliser
not be represented only by a coordinator table entry
```

Scoped work returns standard completion envelopes:

```lua
{
  kind         = "http_operation_done",
  operation_id = operation_id,
  generation   = generation,

  status = "ok", -- "failed" or "cancelled"
  report = report,

  result  = result_table, -- when ok
  primary = primary,      -- when not ok
}
```

Completion handling must be stale-safe:

```lua
local rec = state.operations[ev.operation_id]
if not rec or rec.generation ~= ev.generation then
  return
end
```

Store completion before reporting it. Reporters do not join unless explicitly delegated as reapers.

Child failure is data until the coordinator applies policy.

---

## 15. Joining and scoped work

`join_op()` is active finalisation, not passive observation.

It may:

```text
close admission
wait for fibres
join children
run finalisers
record outcome
detach the child scope
```

Join authority is therefore explicit.

Rules:

```text
parent join is the structural reaper
early reaping must be named
non-parent reaping must be delegated
reporters do not join
ordinary early reapers wait for worker body-ended
early join before body-ended is for cancellation or abort only
```

Use `devicecode/support/scoped_work.lua` for child work whose completion must be materialised before ordinary parent finalisation.

Use it for:

```text
one-shot exchange
open-exchange setup
connect-websocket setup
body-copy work with service-visible completion
explicit graceful close/shutdown work
backend component supervision
```

Do not use it merely to wrap a simple Op with no distinct lifetime.

---

## 16. Security and egress policy

HTTP is SSRF-capable. Policy is part of the service contract.

Capability authorisation decides whether the caller may use HTTP.

Egress policy decides whether this specific request target, method, redirect chain, TLS mode and body policy are permitted.

URI and authority parsing should go through the lua-http-backed utility boundary in `services/http/transport/uri.lua`, so policy validates the same URI grammar that the backend will consume. Policy code should not maintain a separate ad hoc URI parser.

Both must pass before backend admission.

Policy should cover:

```text
allowed schemes
allowed methods
host allow/deny rules
private address access
loopback access
DNS policy
redirect policy
TLS verification
maximum header bytes
maximum request body bytes
maximum response body bytes
maximum exchange duration
principal/origin permissions
```

Policy checks should happen before backend admission where possible.

Stable public errors include:

```text
invalid_args
forbidden
unsupported_scheme
host_denied
backend_unavailable
connect_failed
tls_failed
timeout
request_body_too_large
response_body_too_large
accept_queue_full
closed
cancelled
aborted
```

Backend-specific errors may appear in diagnostics, but should not accidentally become the public contract.

---

## 17. Models and retained status

HTTP exposes retained capability status and a pulse-backed model.

Model fields should be driven by owned event sources, not guesses.

Suggested fields:

```text
state
backend
ready
active_listeners
active_contexts
active_exchanges
active_websockets
completed_exchanges
failed_exchanges
rejected_requests
last_error
policy_generation
```

Model rules:

```text
snapshot returns a copy
changed_op returns versioned snapshots
updates are non-yielding
updates signal only on material change
terminate(reason) wakes observers
models do not perform Ops
models do not publish directly
```

The service coordinator decides what to retain at:

```text
svc/http/status
cap/http/main/status
cap/http/main/state/stats
```

---

## 18. Finalisers

Finalisers release owned resources immediately.

The rule is:

```text
Finalisers must not hide suspension.
```

Allowed:

```text
terminate driver
terminate listener
terminate unaccepted contexts
terminate still-owned contexts
terminate exchange
terminate websocket
terminate source/sink leases
terminate model
cancel child scopes without waiting
detach local registrations
unbind/unretain through documented immediate bus cleanup
perform explicit try-now Ops that cannot wait
```

Not allowed:

```text
perform on Ops that may wait
perform_raw
sleep
join or join_op
HTTP read/write/flush
WebSocket send/receive
blocking queue send
graceful close handshakes
backend calls that may block
close_op
retry loops
```

Cleanup vocabulary:

```text
terminate(reason)
  immediate, idempotent, non-yielding, finaliser-safe

close_op()
  graceful protocol work, may wait
```

Resources owned by finalisers must expose `terminate(reason)` or equivalent.

---

## 19. Event ordering and backpressure

`choice`, `named_choice` and `first_ready` select readiness, not priority.

Default design should be order-tolerant through:

```text
identity
generation checks
idempotent termination
stale completion handling
at-most-once replies
model update from current state
```

Use `devicecode/support/priority_event.lua` only where order affects safety, ownership, authority or externally visible correctness.

Examples:

```text
backend failure before admitting new work
listener termination before accepting ready contexts
stored completion before admitting work that depends on freed capacity
policy generation change before applying generation-bound completions
```

Backpressure policy must be explicit:

```text
reject
terminate
cancel operation
mark degraded
fail observing scope
slow a worker or I/O owner
```

Completion events must not be silently dropped while the observing scope is healthy.

---

## 20. UI consumption model

UI consumes HTTP. It does not own the HTTP stack.

HTTP owns:

```text
cqueues driver
lua-http backend
listener construction
context command loop
HTTP client exchanges
WebSocket transport
immediate transport termination
```

UI owns:

```text
route decoding
authentication/session policy
HTTP request scopes
response ownership
static-file policy
WebSocket client coordinators
UI read model
update upload policy
```

Preferred direction:

```text
UI asks cap/http/main to listen.
HTTP returns an HttpListener local handle.
UI accepts HttpContext handles.
UI request scopes perform context Ops.
```

UI coordinators must not perform HTTP or WebSocket I/O inline.

---

## 21. SDK contract

`services/http/sdk.lua` provides an op-first bus client.

Example:

```lua
local http = require "services.http".sdk
local ref = http.new_ref(conn, "main")

local status = fibers.perform(ref:status_op())

local reply = fibers.perform(ref:listen_op({
  host = "127.0.0.1",
  port = 8080,
}))

local listener = reply.listener
```

Suggested methods:

```text
status_op
listen_op
open_exchange_op
exchange_op
connect_ws_op
```

The SDK must make locality explicit:

```text
handle-returning methods are local-only
descriptor-based methods are remote-capable in shape
all methods return Ops
```

---

## 22. Module structure

Target structure:

```text
src/services/
  http.lua

  http/
    architecture_note.md
    service.lua
    topics.lua
    cap_surface.lua
    model.lua
    policy.lua
    sdk.lua
    errors.lua

    client.lua
    exchange.lua
    listener.lua
    context.lua
    websocket.lua
    body.lua

    transport/
      cqueues_driver.lua
      lua_http.lua
      websocket.lua
```

Ownership by file:

```text
http.lua
  public entry point

service.lua
  service coordinator, active handle registry, operation admission, completion policy

cap_surface.lua
  bus endpoints, retained cap metadata/status/state, cleanup

model.lua
  pulse-backed service model

policy.lua
  validation, egress policy, principal/origin checks

sdk.lua
  op-native consumer SDK

errors.lua
  stable error mapping

client.lua
  outgoing one-shot and setup operations

exchange.lua
  HttpExchange handle

listener.lua
  HttpListener handle and accept ownership

context.lua
  HttpContext handle

websocket.lua
  WebSocket handle

body.lua
  body source/sink descriptors and copy operations

transport/*
  cqueues/lua-http/WebSocket backend integration
```

Current `ui/transport/*` modules should move under `services/http/transport/*`. Compatibility shims should not remain once callers and tests have moved.

---

## 23. Test requirements

Critical tests:

```text
HTTP service code does not use perform_raw
only services/http/transport requires cqueues or lua-http
coordinator branches do not suspend
cap/http/main/meta and status are retained
cap RPC endpoints bind and unbind cleanly
handle-returning RPCs reject or fail clearly when invoked by a non-local or Fabric-serialised caller


driver termination wakes pending run_op
losing run_op aborts before execution where possible
multiple run_ops share one pump
readiness is treated as a hint
spurious readiness is non-fatal

listener accepts contexts through accept_op
listener overflow terminates context
listener termination wakes accept waiters
listener terminates only unaccepted contexts
accepted context ownership transfers to caller scope

context stream commands run in the lua-http command loop
losing stream command is abandoned
context termination wakes pending commands
context termination is idempotent

open_exchange handoff keeps returned exchange alive
failed open cleans up exchange
service finaliser terminates live exchanges
exchange close updates registry state

one-shot exchange uses source/sink descriptors
raw chunks in bus payload are rejected
large responses do not create bus chunk messages
source and sink are terminated on cancellation
committed sink ownership is not reclaimed without contract

completion carries operation_id and generation
stale completions are ignored
completion is stored before reporting
reporter does not join
reaper failure is surfaced

policy rejects forbidden work before backend admission where possible
policy errors are stable

finalisers do not wait
finalisers do not use perform_raw, sleep, join or close_op
terminate(reason) is idempotent and non-yielding
models terminate and wake observers
```

Integration tests should retain the current real backend coverage:

```text
real HTTP GET through listener/context
real POST body read and echo
real listener termination wakes pending accept
real concurrent HTTP requests complete
real WebSocket echo round trip
real driver termination wakes pending cqueues job
```

---

## 24. Compact rules

```text
HTTP is a system capability service.
The bus is control plane only.
Keep bytes off the bus.
Use local handles for local streaming.
Use descriptors for remote-capable work.

Use fibers.perform for waits.
Use fibers.spawn for current-scope work.
Use scoped_work.start for identity-bearing child work.
Use terminate(reason) in finalisers.
Use close_op() only for graceful work.

Coordinators observe, decide and dispatch immediate effects.
Coordinators do not perform protocol I/O.
cqueues and lua-http stay behind services/http/transport.

A returned handle must survive its setup operation.
Registry ownership is a shutdown backstop.
Caller ownership is normal use.
Cleanup is idempotent.

Every listener, context, exchange, websocket, source and sink has an owner.
Every completion carries identity.
Every descriptor resolution checks authority.
Every summary field comes from an owned event source.
```

---

## 25. Event-port component boundary

HTTP service components report through `devicecode.support.service_events` ports.
The coordinator remains the owner of model reduction and retained status.

```text
backend owner       -> events_port -> HTTP coordinator
listener owner      -> events_port -> HTTP coordinator
listener contexts   -> events_port -> HTTP coordinator
operation workers   -> events_port -> HTTP coordinator
registry accounting -> events_port -> HTTP coordinator
```

The lower transport layer may still contain callback-shaped adapter seams for
cqueues/lua-http compatibility. The HTTP service does not pass parent-state
callbacks into listener context admission; it gives the listener an event port.
Context admission, transfer, termination and server-side websocket registration
are semantic events with listener identity and generation.
