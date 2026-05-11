# UI architecture note

UI is a consumer of the system HTTP capability, not an HTTP transport owner.

## Purpose

The UI service owns application semantics:

```text
static UI route policy
server-sent events over read-model watches
firmware upload policy and update-service handoff
authentication and local sessions
read-only projections over retained service state
UI status and summary publication
```

The HTTP service owns:

```text
cqueues driver
lua-http backend
HTTP listener construction
HTTP context command loops
WebSocket transport capability for future consumers
immediate transport termination
```

UI depends on `services.http.sdk` and public HTTP handles. No UI module should
require cqueues, raw lua-http, or `services.http.transport`.

## Lifetime shape

```text
ui service scope
  service coordinator
  read-model component
  HTTP listener consumer component
    HttpListener local handle from cap/http/main
    HTTP request scopes
      static response scopes
      SSE response scopes
      firmware upload scopes
```

A request scope owns one accepted `HttpContext` after listener handoff. It
installs immediate termination before any cancellable wait. Graceful response
work is done in the request scope; finalisers terminate immediately.

## HTTP consumption

UI obtains an HTTP listener using the HTTP SDK:

```lua
local ref = require('services.http').sdk.new_ref(conn, 'main')
local reply = fibers.perform(ref:listen_op({ host = '127.0.0.1', port = 8080 }))
local listener = reply.listener
```

The listener component accepts `HttpContext` handles and starts request scopes.
The UI service coordinator never performs HTTP I/O.

## First-cut routes

```text
GET  /...                    static files
GET  /events                 server-sent events from the UI read model
POST /api/update/upload      MCU firmware upload to the update/artifact boundary
GET  /api/state/...          read-model queries
POST /api/login              login
GET  /api/session            session snapshot
POST/DELETE /api/session     logout
POST /api/call/...           authenticated command forwarding
```

## Boundaries

```text
services/ui/http/listener.lua
  consumes cap/http/main and owns request admission

services/ui/http/request.lua
  owns one request lifetime and routes work

services/ui/http/response.lua
  owns one response state machine

services/ui/http/static.lua
  owns static file response work

services/ui/http/sse.lua
  owns SSE streaming over local read-model watches

services/ui/update/upload.lua
  owns upload body streaming and ingest handoff
```

## Rules

```text
UI service code does not use perform_raw.
UI service code does not require cqueues or lua-http.
UI service code does not require services.http.transport.
The service coordinator blocks only at its control point.
Request scopes may perform HTTP read/write Ops.
Finalisers use terminate(reason) only; graceful closure belongs in close_op().
Response ownership is explicit.
Upload ownership transfer is explicit.
```

## Event-port listener boundary

The UI service treats its HTTP listener as a component/source rather than a
callback target.

```text
UI service coordinator
  owns listener_generation
  owns active request counts
  owns summary publication

UI HTTP listener component
  accepts contexts from cap/http
  starts request scopes
  emits request lifecycle events through devicecode.support.service_events
```

Listener lifecycle events carry `listener_id` and `generation`. The coordinator
ignores stale request events from a replaced listener. The listener module keeps a
raw `done_tx` path only as an isolated compatibility seam for older unit tests;
service wiring uses `events_port`.

Command forwarding is expressed through `user_operation.run_op` and
`conn:call_op`, so the request scope owns the wait and command specs no longer
hide a blocking `conn:call` behind an ordinary function.
