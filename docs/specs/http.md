# HTTP service guide

## Purpose

HTTP owns the transport boundary for HTTP and WebSocket work.

It is responsible for:

```text
cqueues/lua-http integration
HTTP listener creation
HTTP client exchange
server-side accepted contexts
WebSocket transport handles
request/response command loops
immediate transport termination
HTTP capability publication
transport observability
```

HTTP is an infrastructure service. UI and other services consume it through public HTTP capability handles.

## Lifetime shape

```mermaid
flowchart TD
  HttpScope["http service scope"] --> Coordinator["coordinator"]
  HttpScope --> Registry["handle registry"]
  HttpScope --> Backend["transport driver scope"]
  HttpScope --> Publisher["cap/http publisher"]

  Coordinator --> Listener["listener scopes"]
  Coordinator --> Exchange["client exchange scopes"]
  Coordinator --> WS["websocket scopes"]

  Listener --> Context["accepted HttpContext handles"]
  Context --> Consumer["consumer request scope"]
  Exchange --> Backend
  WS --> Backend

  Publisher --> Cap["cap/http/main/..."]
  Publisher --> Stats["cap/http/main/state/stats"]
  Publisher --> Obs["obs/v1/http/metric/main/stats"]
```

Callbacks from transport code must not mutate service model state directly. They may update backend-local state and wake an Op-facing boundary.

## Public surfaces

HTTP should publish:

```text
svc/http/status
svc/http/meta
cfg/http

cap/http/main/meta
cap/http/main/status
cap/http/main/rpc/listen
cap/http/main/rpc/open-exchange
cap/http/main/rpc/connect-ws
cap/http/main/state/stats

obs/v1/http/metric/main/stats
```

`cap/http/main/state/stats` is a narrow interface-scoped adjunct. Canonical domain state should not be hidden there.

## Consumption pattern

A consumer should use the SDK:

```lua
local http = require('services.http').sdk
local ref = http.new_ref(conn, 'main')

local reply = fibers.perform(ref:listen_op({
  host = '127.0.0.1',
  port = 8080,
}))

local listener = reply.listener
```

The consumer owns accepted contexts after handoff. HTTP owns unaccepted contexts and transport handles until ownership transfer.

## Op-only boundary

Transport operations should be Op-first:

```text
construct Op
admit command to driver
run backend step
return public wrapper or result
terminate immediately on losing choice/cancellation
```

Transport wrappers must provide `terminate(reason)`.

Graceful protocol closure belongs in `close_op()` and only in request/worker scopes that may wait.

## Reviewer checklist

```text
Only transport modules require cqueues or lua-http.
Service code does not use perform_raw.
Public methods use kebab-case.
Returned handles are public wrappers, not backend objects.
Callbacks do not reduce service state directly.
Accepted context ownership transfer is explicit.
Losing HTTP/WebSocket Ops terminate active backend work.
Stats under cap/.../state are narrow.
Metrics also appear under obs/v1/http/...
```
