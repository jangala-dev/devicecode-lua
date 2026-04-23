# UI Service

## Purpose

The UI service is the local operator-facing application service responsible for:

1. serving static assets
2. exposing an authenticated JSON HTTP API
3. exposing a session-bound WebSocket control channel
4. maintaining a local retained-state read model over selected topic spaces
5. opening user-scoped bus connections for delegated operations
6. publishing coarse retained UI state under `state/ui/main`
7. publishing a service announcement under `svc/<name>/announce`

The service is intentionally a thin front door rather than a policy engine. It does not implement config, update, fabric, or device policy itself. It authenticates a user, opens a user-scoped connection, delegates to existing service endpoints, and serves a stable browser-facing surface over HTTP and WebSocket.

## Dependencies

### Internal retained model sources

By default the service starts an internal retained-state model that replays and follows:

| Pattern | Usage |
|---|---|
| `{'cfg','#'}` | Configuration reads and config snapshots |
| `{'svc','#'}` | Service announce/status inspection |
| `{'state','#'}` | State inspection, fabric views, update job views, device views, and general UI reads/watches |

These are consumed through the in-process UI model rather than being exposed directly to browser callers.

### User-scoped connections

For authenticated operations the service uses `opts.connect(principal, origin_extra)` to create or adopt a user-scoped local bus connection.

That user connection is then used for delegated operations such as:

| Surface | Usage |
|---|---|
| `{'config', <service>, 'set'}` | config set helper |
| `{'cmd','update','job', ...}` | update job create/get/list/do |
| `artifact_store/main` capability | update upload ingress |

The UI service itself does not talk to HAL directly.

### Environment dependency

The default bootstrap login verifier uses:

| Variable | Usage |
|---|---|
| `DEVICECODE_UI_ADMIN_PASSWORD` | Password for the built-in `admin` user when `opts.verify_login` is not supplied |

## Startup options

The current service is configured through `start(conn, opts)` rather than through retained `cfg/ui`.

Relevant options are:

```lua
{
  name = <string|nil>,
  env = <string|nil>,

  connect = function(principal, origin_extra) ... end,   -- required
  verify_login = function(username, password) ... end,   -- optional

  session_ttl_s = <number|nil>,
  session_prune_s = <number|nil>,
  model_ready_timeout_s = <number|nil>,
  model_queue_len = <number|nil>,
  model_sources = { ... } | nil,

  host = <string|nil>,
  port = <number|nil>,
  www_root = <string|nil>,

  run_http = <function|nil>,
}
```

### Default runtime values

If not supplied:

```lua
{
  name = 'ui',
  session_ttl_s = 3600,
  session_prune_s = 60,
  model_ready_timeout_s = 2.0,
  model_sources = {
    { name = 'cfg',   pattern = { 'cfg', '#' } },
    { name = 'svc',   pattern = { 'svc', '#' } },
    { name = 'state', pattern = { 'state', '#' } },
  },
  host = '0.0.0.0',
  port = 80,
}
```

There is no retained config watch in the current implementation.

## Authentication and session model

### Login verification

If `opts.verify_login` is not supplied, the service uses the bootstrap verifier:

- username must be `admin`
- password must match `DEVICECODE_UI_ADMIN_PASSWORD`
- success yields a principal equivalent to `authz.user_principal('admin', { roles = { 'admin' } })`

A custom verifier may instead return any suitable local principal.

### Session storage

Sessions are stored in-memory only.

Each session record includes:
- `id`
- `principal`
- public user identity derived from that principal
- expiry timestamp

Sessions are:
- created on successful login
- touched on each authenticated request
- pruned periodically by the UI shell
- deleted explicitly on logout

The public session payload returned to clients is the value from `sessions:public(rec)`.

### Session transport

For HTTP and WebSocket, the service accepts session ids from either:

- cookie `devicecode_session=<id>`
- header `x-session-id: <id>`

On successful HTTP login, the service sets:

```text
Set-Cookie: devicecode_session=<id>; Path=/; HttpOnly; SameSite=Strict
```

On logout, it clears that cookie.

## Retained topics published

### Service announce

The service retains:

| Topic | Usage |
|---|---|
| `{'svc', <service_name>, 'announce'}` | Coarse operator-facing service capability advertisement |

Default announce payload:

```lua
{
  role = 'ui',
  auth = 'local-session',
  caps = {
    login = true,
    logout = true,
    session = true,
    model_exact = true,
    model_snapshot = true,
    config_get = true,
    config_set = true,
    service_status = true,
    services_snapshot = true,
    fabric_status = true,
    fabric_link_status = true,
    watch = true,
    update_job_create = true,
    update_job_get = true,
    update_job_list = true,
    update_job_do = true,
    update_job_upload = true,
  },
}
```

### Aggregate UI state

The service retains:

| Topic | Payload kind |
|---|---|
| `{'state','ui','main'}` | `ui.main` |

Payload shape:

```lua
{
  status = 'starting' | 'running' | 'failed',
  sessions = <integer>,
  clients = <integer>,
  model_ready = <boolean>,
  model_seq = <integer>,
  t = <monotonic seconds>,
  reason = <string|nil>,
}
```

Semantics:
- `sessions` = current in-memory session count
- `clients` = current connected WebSocket client count
- `model_ready` = retained model bootstrap complete
- `model_seq` = current retained model sequence
- `status` = UI shell status

### Audit events

The service publishes local operator audit events under:

| Topic prefix | Usage |
|---|---|
| `{'obs','audit','ui', <kind>}` | Successful login/logout and config set audit facts |

Current audit kinds emitted directly by the service include:
- `login`
- `logout`
- `config_set`

## Internal retained model

The UI model is an in-process retained-state cache over configured source patterns.

Responsibilities:
- replay retained state from each configured source watch
- maintain a local trie keyed by exact topic
- provide exact lookup
- provide pattern snapshot
- provide watch streams with replay followed by live retain/unretain events
- expose readiness and monotonic change sequence

### Exact lookup

`model:get_exact(topic)` returns:

```lua
{
  topic = <topic>,
  payload = <payload>,
  origin = <string|nil>,
  seq = <integer>,
}
```

### Snapshot

`model:snapshot(pattern)` returns:

```lua
{
  seq = <integer>,
  entries = {
    {
      topic = <topic>,
      payload = <payload>,
      origin = <string|nil>,
      seq = <integer>,
    },
    ...
  }
}
```

### Watch streams

`model:open_watch(pattern, opts)` returns a watch object that first replays the current snapshot and then yields live changes.

Replay events:

```lua
{ op = 'retain', phase = 'replay', topic = <topic>, payload = <payload>, origin = <origin>, seq = <integer> }
{ op = 'replay_done', seq = <model_seq> }
```

Live events:

```lua
{ op = 'retain', phase = 'live', topic = <topic>, payload = <payload>, origin = <origin>, seq = <integer> }
{ op = 'unretain', phase = 'live', topic = <topic>, origin = <origin>, seq = <integer> }
```

Watch streams are bounded. If a watch mailbox overflows, that watch is closed.

## Browser-facing transport surfaces

The service currently exposes:

- static file serving (optional)
- JSON HTTP API under `/api/...`
- WebSocket API at `/ws`

## HTTP API

Unless otherwise noted:
- responses are JSON
- success shape is `{ ok = true, data = <value> }`
- failure shape is `{ ok = false, err = <string>, code = <string> }`

### Authentication/session endpoints

#### `POST /api/login`

Request:

```lua
{ username = <string>, password = <string> }
```

Response data:

```lua
<public session record>
```

Also sets the session cookie.

#### `POST /api/logout`

Uses current session from cookie/header.

Response data:

```lua
{ ok = true }
```

Also clears the session cookie.

#### `GET /api/session`

Returns the current public session record.

### Health and retained-model endpoints

#### `GET /api/health`

Returns:

```lua
{
  service = <service name>,
  now = <monotonic seconds>,
  sessions = <integer>,
  model_ready = <boolean>,
  model_seq = <integer>,
}
```

#### `POST /api/model/exact`

Request:

```lua
{ topic = <concrete topic> }
```

Returns one model entry.

#### `POST /api/model/snapshot`

Request:

```lua
{ pattern = <topic pattern> }
```

Returns one model snapshot.

### Service/config/fabric inspection endpoints

#### `GET /api/services`

Returns a snapshot containing:
- retained `svc/*/announce`
- retained `svc/*/status`

#### `GET /api/config/<service>`

Returns retained `cfg/<service>` from the UI model.

#### `POST /api/config/<service>`

Request:

```lua
{ data = <plain table> }
```

Delegates to:

```lua
{ 'config', <service>, 'set' }
```

over a user-scoped bus connection.

#### `GET /api/service/<service>/status`

Returns retained `svc/<service>/status` from the UI model.

#### `GET /api/fabric`

Returns a combined fabric view containing:
- retained `state/fabric`
- retained `state/fabric/link/<id>/<view>` grouped by link id

#### `GET /api/fabric/link/<link_id>`

Returns:
- `session`
- `bridge`
- `transfer`

for that retained fabric link state, if present.

### Update job endpoints

#### `GET /api/update/jobs`

Returns the result of `cmd/update/job/list`.

#### `POST /api/update/jobs`

Request payload is forwarded to `cmd/update/job/create`.

#### `GET /api/update/jobs/<job_id>`

Returns the result of `cmd/update/job/get`.

#### `POST /api/update/jobs/<job_id>/do`

Request body is forwarded to `cmd/update/job/do` after injecting `job_id`.

#### `POST /api/update/uploads`

This is the browser upload ingress path for uploaded update artefacts.

Request body:
- raw octet stream

Optional headers:
- `x-artifact-component`
- `x-artifact-name`
- `x-artifact-version`
- `x-artifact-build`
- `x-artifact-checksum`

Flow:

1. validate session
2. open a user-scoped connection
3. open `artifact_store/main`
4. call `create_sink` with transient upload metadata
5. stream request body into the sink in chunks
6. `commit()` the sink to an artefact
7. create an update job referencing that artefact
8. start the job immediately

Response data:

```lua
{
  ok = true,
  job = <public update job>,
  artifact = {
    ref = <artifact_ref>,
    size = <integer>,
    checksum = <string|nil>,
  }
}
```

## WebSocket API

WebSocket endpoint:

```text
GET /ws
```

The WebSocket transport is request/response plus watch-event multiplexing.

### Reply shape

For normal replies:

```lua
{
  id = <request id|nil>,
  ok = <boolean>,
  data = <value|nil>,
  err = <string|nil>,
  code = <string|nil>,
}
```

### Watch event shape

```lua
{ op = 'watch_event', watch_id = <string|number|nil>, event = <watch event> }
{ op = 'watch_closed', watch_id = <string|number|nil>, reason = <string> }
```

### Session handling

On socket open, the transport may adopt an initial session from:
- cookie `devicecode_session`
- header `x-session-id`

It can also change/adopt session after a successful `login` operation.

When the active session changes:
- all open watches are closed
- the old user connection is disconnected
- a new user connection is opened for the adopted session

### Supported WebSocket operations

- `hello`
- `session`
- `health`
- `login`
- `logout`
- `config_get`
- `config_set`
- `service_status`
- `services_snapshot`
- `fabric_status`
- `fabric_link_status`
- `model_exact`
- `model_snapshot`
- `watch_open`
- `watch_close`

### Not exposed on WebSocket today

The current WebSocket implementation does **not** expose update-job create/get/list/do/upload operations.

## Query/helper semantics

### `services_snapshot`

Returns:

```lua
{
  seq = <integer>,
  announce = { [<service>] = <announce payload>, ... },
  status = { [<service>] = <status payload>, ... },
}
```

### `fabric_status`

Returns:

```lua
{
  seq = <integer>,
  main = <state/fabric payload|nil>,
  links = {
    [<link_id>] = {
      session = <payload|nil>,
      bridge = <payload|nil>,
      transfer = <payload|nil>,
      ...
    }
  }
}
```

### `fabric_link_status`

Returns:

```lua
{
  session = <payload|nil>,
  bridge = <payload|nil>,
  transfer = <payload|nil>,
}
```

## Error model

The service normalises errors through `services.ui.errors`.

Errors may carry:
- message
- code
- HTTP status

Common categories include:
- `bad_request`
- `unauthorised`
- `not_found`
- `not_ready`
- `unavailable`
- upstream/transport-derived failures

HTTP routes and WebSocket replies both surface these normalised errors.

## Service flow

### UI shell

1. require `opts.connect`
2. create session store
3. start retained UI model
4. wait for model bootstrap
5. retain `svc/ui/announce`
6. retain `state/ui/main`
7. spawn HTTP server
8. react to local state changes, model changes, and prune ticks
9. republish aggregate state whenever sessions, clients, or model status changes

### HTTP request path

1. transport decodes request and session
2. route onto the UI app façade
3. for read helpers, query the local UI model
4. for delegated actions, open or reuse a user-scoped connection and call into the service mesh
5. encode result or normalised error as JSON

### WebSocket watch path

1. open WebSocket
2. optionally adopt session from headers
3. create or replace watches on `watch_open`
4. replay retained snapshot
5. emit live retain/unretain events
6. close all watches when session changes or the socket closes

## Architecture notes

- the service is deliberately a local operator façade, not a business-logic service
- authentication is local-session based and currently bootstrap-friendly by default
- all privileged work runs through user-scoped bus connections so the caller principal is preserved
- the retained UI model is the read path for snapshots and watches; it avoids repeated direct retained walks by browser callers
- HTTP and WebSocket share the same app façade, but not every capability is exposed on both transports
- uploaded artefacts are normalised through `artifact_store.create_sink` rather than direct filesystem access
- browser-visible aggregate state is intentionally small: rich reads come from the UI model and delegated helper endpoints
