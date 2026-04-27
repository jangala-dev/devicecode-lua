# UI Service

## Purpose

The UI service is the local operator-facing application service responsible for:

1. serving static assets when `www_root` is configured
2. exposing an authenticated JSON HTTP API
3. exposing a session-bound WebSocket control channel
4. maintaining an in-process retained-state read model over selected topic spaces
5. opening user-scoped bus connections for delegated operations
6. publishing service lifecycle and metadata via `svc/<name>/status`, `svc/<name>/meta` and the legacy-compatible `svc/<name>/announce`
7. emitting UI-origin observability events under `obs/v1/ui/...`

The service is intentionally a thin front door rather than a policy engine. It does not implement config, update, fabric or device policy itself. It authenticates a user, opens or reuses a user-scoped connection, delegates to existing service endpoints and capabilities, and serves a stable browser-facing surface over HTTP and WebSocket.

The service does **not** currently publish a UI-owned retained state document such as `state/ui/main`.

## Dependencies

### Internal retained model sources

By default the service starts an internal retained-state model that replays and follows these topic spaces:

| Pattern         | Usage                                                                  |
| --------------- | ---------------------------------------------------------------------- |
| `{'cfg','#'}`   | Configuration reads and config snapshots                               |
| `{'svc','#'}`   | Service metadata and service lifecycle/status inspection               |
| `{'state','#'}` | State inspection, including fabric views and update workflow state     |
| `{'cap','#'}`   | Capability metadata and status inspection where needed by the UI model |
| `{'raw','#'}`   | Raw source/capability inspection where needed by the UI model          |

These are consumed through the in-process UI model rather than being exposed directly to browser callers.

### User-scoped connections

For authenticated delegated operations the service uses `opts.connect(principal, origin_extra)`.

The service uses user-scoped connections in two distinct ways:

* **HTTP-style delegated work**: it opens a temporary user-scoped connection for one bounded operation
* **WebSocket session work**: it keeps one current user-scoped connection bound to the current authenticated session and reuses it across WebSocket calls and watches until logout, session change or socket close

Delegated operations currently use these surfaces:

| Surface                                           | Usage                                                  |
| ------------------------------------------------- | ------------------------------------------------------ |
| `{'config', <service>, 'set'}`                    | config set helper                                      |
| `{'cap','update-manager','main','rpc', <method>}` | update job create/get/list/action                      |
| `artifact-ingest/main` curated capability         | upload ingress (`create`, `append`, `commit`, `abort`) |

The UI service itself does not talk to HAL directly. Uploads are staged through the curated `artifact-ingest/main` capability on a user-scoped connection.

### Environment dependency

If `opts.verify_login` is not supplied, the bootstrap login verifier uses:

| Variable                       | Usage                                  |
| ------------------------------ | -------------------------------------- |
| `DEVICECODE_UI_ADMIN_PASSWORD` | Password for the built-in `admin` user |

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
  model_queue_len = 512,
  model_sources = {
    { name = 'cfg',   pattern = { 'cfg', '#' } },
    { name = 'svc',   pattern = { 'svc', '#' } },
    { name = 'state', pattern = { 'state', '#' } },
    { name = 'cap',   pattern = { 'cap', '#' } },
    { name = 'raw',   pattern = { 'raw', '#' } },
  },
  host = '0.0.0.0',
  port = 80,
}
```

Notes:

* `host` and `port` defaulting is ultimately applied by the HTTP transport
* there is no retained config watch in the current implementation
* upload limits and upload timeout are **not** currently exposed through `start(conn, opts)`; they are internal defaults of the upload helper

## Authentication and sessions

### Login verification

If `opts.verify_login` is not supplied, the service uses the bootstrap verifier:

* username must be `admin`
* password must match `DEVICECODE_UI_ADMIN_PASSWORD`
* success yields a principal equivalent to `authz.user_principal('admin', { roles = { 'admin' } })`
* if `DEVICECODE_UI_ADMIN_PASSWORD` is unset, login fails with a service-unavailable style error

A custom verifier may instead return any suitable local principal.

### Session storage

Sessions are stored in-memory only.

Each session record includes:

* `id`
* `principal`
* public user identity derived from that principal
* `created_at`
* `expires_at`

Sessions are:

* created on successful login
* touched on each authenticated request
* pruned periodically by the UI shell
* deleted explicitly on logout

The public session payload returned to clients is:

```lua
{
  session_id = <string>,
  user = {
    id = <string>,
    kind = <string|nil>,
    roles = <string[]>,
  },
  created_at = <number>,
  expires_at = <number>,
}
```

### Session transport

For HTTP and WebSocket, the service accepts session ids from either:

* cookie `devicecode_session=<id>`
* header `x-session-id: <id>`

On successful HTTP login, the service sets:

```text
Set-Cookie: devicecode_session=<id>; Path=/; HttpOnly; SameSite=Strict
```

On logout, it clears that cookie.

For WebSocket:

* if a session id is present in the upgrade headers, the socket adopts that session on connect
* later `login` swaps the current session and reopens the current user connection
* `logout` clears the current session, closes watches and drops the current user connection

## Retained topics published

### Service metadata and lifecycle

The service uses `devicecode.service_base`, so it retains:

| Topic                                 | Usage                            |
| ------------------------------------- | -------------------------------- |
| `{'svc', <service_name>, 'meta'}`     | canonical service metadata       |
| `{'svc', <service_name>, 'announce'}` | legacy-compatible announce alias |
| `{'svc', <service_name>, 'status'}`   | lifecycle/status payload         |

The default announced metadata payload is:

```lua
{
  name = <service_name>,
  env = <env>,
  run_id = <uuid>,
  ts = <monotonic seconds>,
  at = <wall clock string>,

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

The lifecycle/status payload currently carries:

```lua
{
  state = 'starting' | 'running' | 'degraded' | 'failed',
  ts = <monotonic seconds>,
  at = <wall clock string>,
  run_id = <uuid>,

  ready = <boolean>,
  sessions = <integer>,
  clients = <integer>,
  model_ready = <boolean>,
  model_seq = <integer>,
  reason = <string|nil>,
}
```

Semantics:

* `sessions` = current in-memory session count
* `clients` = current connected WebSocket client count
* `model_ready` = retained model bootstrap complete
* `model_seq` = current retained model sequence
* `state` = UI shell lifecycle state

### UI-owned retained state

The current implementation does **not** publish a separate retained UI-owned state document such as `state/ui/main`.

### Observability and audit events

The service publishes UI-origin events under:

| Topic prefix                                                              | Usage                                 |
| ------------------------------------------------------------------------- | ------------------------------------- |
| `{'obs','v1','ui','event', <kind>}`                                       | canonical UI events                   |
| `{'obs','event','ui', <kind>}`                                            | legacy-compatible event fanout        |
| `{'obs','log','ui', <level>}`                                             | legacy log fanout                     |
| `{'obs','v1','ui','event','log'}`                                         | canonical log-as-event fanout         |
| `{'obs','state','ui','status'}` and `{'obs','v1','ui','metric','status'}` | retained service status observability |

Current UI-origin event kinds emitted directly by handlers include:

* `login`
* `logout`
* `config_set`

The service also emits log-style observability records such as:

* `login_ok`
* `login_failed`
* `ui_ws_connected`
* `ui_ws_disconnected`
* `http_request`
* `http_listening`

## Internal retained model

The UI model is an in-process retained-state cache over configured source patterns.

Responsibilities:

* replay retained state from each configured source watch
* maintain a local trie keyed by exact topic
* provide exact lookup
* provide pattern snapshot
* provide replay-then-live watch streams
* expose readiness and monotonic change sequence

The model is UI-local only. It does not own upstream retained state.

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

* `recv_op()`
* `recv()`
* `close(reason)`

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

* `retain`
* `unretain`

with `phase = 'live'`.

The model must be ready before `get_exact`, `snapshot` or `open_watch` succeed.

## Browser-facing application surface

The transport-facing application façade currently exposes:

* `login`
* `logout`
* `get_session`
* `health`
* `model_exact`
* `model_snapshot`
* `config_get`
* `config_set`
* `service_status`
* `services_snapshot`
* `fabric_status`
* `fabric_link_status`
* `watch_open`
* `update_job_create`
* `update_job_get`
* `update_job_list`
* `update_job_do`
* `update_job_upload`

Handlers own request validation and delegation.

## HTTP API

The default HTTP transport serves static assets and exposes these JSON endpoints:

| Method / Path                       | Operation                                             |
| ----------------------------------- | ----------------------------------------------------- |
| `POST /api/login`                   | login                                                 |
| `POST /api/logout`                  | logout                                                |
| `GET /api/session`                  | current session                                       |
| `GET /api/health`                   | UI health                                             |
| `GET /api/services`                 | services snapshot                                     |
| `POST /api/model/exact`             | exact retained lookup                                 |
| `POST /api/model/snapshot`          | retained snapshot                                     |
| `GET /api/config/<service>`         | config get                                            |
| `POST /api/config/<service>`        | config set                                            |
| `GET /api/service/<service>/status` | one service status                                    |
| `GET /api/fabric`                   | fabric summary                                        |
| `GET /api/fabric/link/<id>`         | one fabric link view                                  |
| `GET /api/update/jobs`              | update job list                                       |
| `POST /api/update/jobs`             | create update job                                     |
| `GET /api/update/jobs/<job_id>`     | get one update job                                    |
| `POST /api/update/jobs/<job_id>/do` | apply update job action                               |
| `POST /api/update/uploads`          | upload an artefact, create an update job and start it |
| `GET /ws`                           | WebSocket upgrade                                     |

Static assets are served from `www_root` if it is configured. Requests that are not API or WebSocket traffic fall back to static serving, using `index.html` for extensionless paths. If `www_root` is not configured, non-API non-WebSocket requests return 404.

## WebSocket transport

The WebSocket transport is session-bound and uses the same application façade underneath, but it does **not** expose every application method.

Current WebSocket operations are:

* `hello`
* `session`
* `health`
* `login`
* `logout`
* `config_get`
* `config_set`
* `service_status`
* `services_snapshot`
* `fabric_status`
* `fabric_link_status`
* `model_exact`
* `model_snapshot`
* `watch_open`
* `watch_close`

Watch notifications are pushed back as:

* `watch_event`
* `watch_closed`

The UI shell tracks client count and folds it into `svc/ui/status`.

## Delegated operations

### Config

* `config_get` is satisfied from the local UI model
* `config_set` is delegated over a user-scoped connection to:

```lua
{ 'config', <service>, 'set' }
```

### Services and fabric reads

These are satisfied from the local UI model rather than by opening further upstream requests.

### Update jobs

Update job operations are delegated over a user-scoped connection to:

```lua
{ 'cap', 'update-manager', 'main', 'rpc', 'create-job' }
{ 'cap', 'update-manager', 'main', 'rpc', 'get-job' }
{ 'cap', 'update-manager', 'main', 'rpc', 'list-jobs' }
{ 'cap', 'update-manager', 'main', 'rpc', 'start-job' }
{ 'cap', 'update-manager', 'main', 'rpc', 'commit-job' }
{ 'cap', 'update-manager', 'main', 'rpc', 'cancel-job' }
{ 'cap', 'update-manager', 'main', 'rpc', 'retry-job' }
{ 'cap', 'update-manager', 'main', 'rpc', 'discard-job' }
```

Current UI action mapping for `update_job_do` is:

* `start`
* `commit`
* `cancel`
* `retry`
* `discard`

### Uploads

`update_job_upload`:

* requires an authenticated session
* currently allows only component `mcu`
* reads the HTTP request body incrementally with a current hard limit of `512 * 1024` bytes
* stages the uploaded body through the curated `artifact-ingest/main` capability using:

  * `create`
  * `append`
  * `commit`
  * `abort`
* creates an update job whose artefact is a ref:

  * `artifact = { kind = 'ref', ref = <artifact ref> }`
* sets update metadata:

  * `source = 'ui_upload'`
  * `name`
  * `build`
  * `checksum`
  * `uploaded = true`
  * `commit_policy = 'manual'`
  * `require_explicit_commit = true`
* starts the job immediately
* does **not** auto-commit the job

The current success payload is:

```lua
{
  ok = true,
  job = <started job>,
  artifact = {
    ref = <string>,
    size = <integer>,
    checksum = <string|nil>,
  },
  update_flow = {
    staged = true,
    requires_commit = true,
    next_action = 'commit',
  },
}
```

So the upload helper both stages the artefact and starts the job, but leaves the final disruptive action as an explicit later commit.
