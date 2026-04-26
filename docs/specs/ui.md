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

The service is intentionally a thin front door rather than a policy engine. It does not implement config, update, fabric or device policy itself. It authenticates a user, opens a user-scoped connection, delegates to existing service endpoints and host capabilities, and serves a stable browser-facing surface over HTTP and WebSocket.

## Dependencies

### Internal retained model sources

By default the service starts an internal retained-state model that replays and follows:

| Pattern | Usage |
|---|---|
| `{'cfg','#'}` | Configuration reads and config snapshots |
| `{'svc','#'}` | Service announce/status inspection |
| `{'state','#'}` | State inspection, fabric views, update job views, device views and general UI reads/watches |

These are consumed through the in-process UI model rather than being exposed directly to browser callers.

### User-scoped connections

For authenticated operations the service uses `opts.connect(principal, origin_extra)` to create or adopt a user-scoped local bus connection.

That user connection is then used for delegated operations such as:

| Surface | Usage |
|---|---|
| `{'config', <service>, 'set'}` | config set helper |
| `{'cmd','update','job', ...}` | update job create/get/list/do |
| `artifact_store/main` capability | update upload ingress |

The UI service itself does not talk to HAL directly; uploads are staged through the UI upload helper using the artifact store capability on the user-scoped connection.

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

## Authentication and sessions

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

The public session payload returned to clients is `sessions:public(rec)`.

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
  status = 'starting' | 'running' | 'degraded' | 'failed',
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

The service publishes operator audit events under:

| Topic prefix | Usage |
|---|---|
| `{'obs','audit','ui', <kind>}` | Successful login/logout and config-set audit facts |

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
  },
}
```

### Watch

`model:open_watch(pattern, opts)` returns a replay-then-live watch handle with:
- `recv_op()`
- `recv()`
- `close()`

Replay items are sent as:

```lua
{
  op = 'retain',
  phase = 'replay',
  topic = <topic>,
  payload = <payload>,
  origin = <string|nil>,
  seq = <integer>,
}
```

followed by:

```lua
{ op = 'replay_done', seq = <integer> }
```

Live items are:
- `retain`
- `unretain`

with `phase = 'live'`.

## Browser-facing application surface

The transport-facing application façade exposes:
- `login`
- `logout`
- `get_session`
- `health`
- `model_exact`
- `model_snapshot`
- `config_get`
- `config_set`
- `service_status`
- `services_snapshot`
- `fabric_status`
- `fabric_link_status`
- `watch_open`
- `update_job_create`
- `update_job_get`
- `update_job_list`
- `update_job_do`
- `update_job_upload`

Handlers own request validation and delegation.

## HTTP API

The default HTTP transport serves static assets and exposes these JSON endpoints:

| Method / Path | Operation |
|---|---|
| `POST /api/login` | login |
| `POST /api/logout` | logout |
| `GET /api/session` | current session |
| `GET /api/health` | UI health |
| `GET /api/services` | services snapshot |
| `POST /api/model/exact` | exact retained lookup |
| `POST /api/model/snapshot` | retained snapshot |
| `GET /api/fabric` | fabric summary |
| `GET /api/fabric/link/<id>` | one fabric link view |
| `GET /api/update/jobs` | update job list |
| `POST /api/update/jobs` | create update job |
| `GET /api/update/jobs/<job_id>` | get one update job |
| `POST /api/update/jobs/<job_id>/do` | apply update job action |
| `POST /api/update/uploads` | upload an artefact and create a manual-commit update job |
| `GET /ws` | WebSocket upgrade |

Static assets are served from `www_root`. Requests that are not API or WebSocket traffic fall back to static serving, using `index.html` for extensionless paths.

## WebSocket transport

The WebSocket transport is session-bound and uses the same application surface underneath.

The UI shell tracks client count and folds it into `state/ui/main`.

## Delegated operations

### Config

`config_set` is delegated over a user-scoped connection to:
- `{'config', <service>, 'set'}`

### Services/fabric reads

These are satisfied from the local UI model rather than by opening further upstream requests.

### Update jobs

Update job operations are delegated over a user-scoped connection to:
- `{'cmd','update','job','create'}`
- `{'cmd','update','job','get'}`
- `{'cmd','update','job','list'}`
- `{'cmd','update','job','do'}`

### Uploads

`update_job_upload`:
- requires an authenticated session
- stages the uploaded request body into `artifact_store/main` through the user-scoped connection
- commits that artefact
- creates an update job with `artifact.kind = 'ref'`
- sets metadata including `source = 'upload'`, file name, content type, size and checksum when available
- forces manual commit by setting:
  - `metadata.require_explicit_commit = true`
  - `metadata.commit_policy = 'manual'`
  - `options.auto_start = true`
  - `options.auto_commit = false`

The upload helper does not itself commit the update; it only stages the artefact and creates/starts the job.
