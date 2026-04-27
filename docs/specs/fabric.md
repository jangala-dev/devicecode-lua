# Fabric Service

## Purpose

The Fabric service supervises configured local link children.

The shell owns:

1. retained `cfg/fabric` consumption
2. desired-versus-live link supervision
3. restart policy for link children
4. aggregate retained summary under `{'state','fabric'}`
5. a public transfer-manager interface under `cap/transfer-manager/main/...`, which routes transfer control requests to the correct live link child

Each live link runs in its own child scope. The child owns:

* transport acquisition and close
* framed reader and writer tasks
* handshake, readiness and liveness
* local/remote publish bridging
* local/remote call bridging
* object transfer

The shell keeps restart policy and aggregate visibility centralised while isolating per-link faults inside child scopes.

## Public surfaces owned by the shell

The shell itself owns:

* `{'svc','fabric','meta'}`
* `{'svc','fabric','status'}`
* `{'state','fabric'}`
* `{'cap','transfer-manager','main','meta'}`
* `{'cap','transfer-manager','main','status'}`
* `{'cap','transfer-manager','main','rpc','send-blob'}`

The shell does **not** own per-link retained component state. That is owned by the link child submodules.

## Dependencies

### Retained configuration

| Topic              | Purpose                                                                       |
| ------------------ | ----------------------------------------------------------------------------- |
| `{'cfg','fabric'}` | Desired link configuration. Watched as retained state with replay on startup. |

The shell accepts either:

* `payload.data.links`
* or `payload.links`
* or a top-level table of link records

### Transport acquisition

The shell does not open transports itself. Each link child opens its own transport through `services.fabric.transport_stream`.

There are two supported forms.

#### 1. Custom open function

If `cfg.transport.open` is a function, it is called as:

```lua
cfg.transport.open(conn, link_id, cfg)
```

It may return either:

* a transport-like object exposing `read_line_op(...)` and `write_line_op(...)`
* or a `fibers` stream-like object exposing `read_line_op(...)` and `write_op(...)`, which will be wrapped into the fabric transport façade

#### 2. Built-in HAL raw-host capability path

Otherwise the built-in path is used.

The transport is opened via a raw host capability reference:

```lua
cap_sdk.new_raw_host_cap_ref(conn, source, class, id)
```

with defaults:

* `class = cfg.transport.class or 'uart'`
* `id = cfg.transport.id or link_id`
* `source = cfg.transport.source or class`
* `open_verb = cfg.transport.open_verb or 'open'`

`open_opts` is:

* `cfg.transport.open_opts`, if supplied
* otherwise constructed via `UARTOpenOpts(read, write)`, with:

  * `read = cfg.transport.read` defaulting to `true`
  * `write = cfg.transport.write` defaulting to `true`

The capability call must return a stream object in the current HAL raw-host contract shape.

### Service-level transfer interface

| Topic                                                 | Purpose                                                  |
| ----------------------------------------------------- | -------------------------------------------------------- |
| `{'cap','transfer-manager','main','rpc','send-blob'}` | Route one transfer control request to a live link child. |

Although the topic name is `send-blob`, the shell accepts three operations over this one endpoint:

* `send_blob`
* `status`
* `abort`

That is the current implementation shape.

## Configuration

After normalisation, the shell works with:

```lua
{
  links = {
    [<link_id>] = {
      id = <string>,

      node_id = <string|nil>,
      member_class = <string|nil>,
      link_class = <string|nil>,

      raw_kind = <string|nil>,
      source_kind = <string|nil>,
      raw_source = <string|nil>,
      member = <string|nil>,
      member_id = <string|nil>,

      restart_backoff_s = <number|nil>,

      transport = {
        class = <string|nil>,
        source = <string|nil>,
        id = <string|nil>,
        terminator = <string|nil>,
        open_verb = <string|nil>,
        open_opts = <table|nil>,
        read = <boolean|nil>,
        write = <boolean|nil>,
        open = <function|nil>,
      } | nil,

      hello_interval_s = <number|nil>,
      ping_interval_s = <number|nil>,
      liveness_timeout_s = <number|nil>,
      read_timeout_s = <number|nil>,
      bad_frame_limit = <number|nil>,
      bad_frame_window_s = <number|nil>,

      rpc_quantum = <number|nil>,
      bulk_quantum = <number|nil>,

      chunk_size = <number|nil>,
      transfer_phase_timeout_s = <number|nil>,

      export_publish_rules = { <rule>, ... } | nil,
      export_retained_rules = { <rule>, ... } | nil,
      import_rules = { <rule>, ... } | nil,
      outbound_call_rules = { <rule>, ... } | nil,
      inbound_call_rules = { <rule>, ... } | nil,

      max_pending_calls = <number|nil>,
      max_inbound_helpers = <number|nil>,
      call_timeout_s = <number|nil>,
    },
  },
}
```

### Link id normalisation

Each link record is normalised with:

```lua
id = v.id or v.link_id or key
```

Records whose resulting `id` is not a non-empty string are ignored.

### Raw source defaults

The child session uses:

```lua
raw_kind = cfg.raw_kind or cfg.source_kind or 'member'
raw_source = cfg.raw_source
          or cfg.member
          or cfg.member_id
          or cfg.member_class
          or cfg.peer_node
          or link_id
```

So, unless overridden, each link appears as a provenance-bearing raw **member** source keyed by link id or member-like identity.

## Topic-map rules

Rules are normalised by `services.fabric.topicmap`.

Accepted rule fields are:

```lua
{
  id = <string|nil>,
  local = { ... } | nil,
  remote = { ... } | nil,
  topic = { ... } | nil,
  timeout = <number|nil>,
}
```

Legacy aliases such as:

* `local_prefix`
* `remote_prefix`
* `from`
* `to`
* `from_prefix`
* `to_prefix`

are rejected.

### Rule semantics

* `export_publish_rules`
  local non-retained publish -> remote `pub retain=false`

* `export_retained_rules`
  local retained watch -> remote retained `pub`

* `import_rules`
  remote `pub` / `unretain` -> local publish / retain / unretain

* `outbound_call_rules`
  local bound endpoint -> remote `call`

* `inbound_call_rules`
  remote `call` -> local `conn:call(...)`

### Exact-topic rules

The topic-map helper supports exact-topic rules via `topic = {...}` and checks rules in order.

However, note the important runtime distinction:

* mapping supports exact-topic rules
* but `rpc_bridge` still binds outbound local endpoints on `rule.local`

So exact-topic rules are supported by the mapper itself, but the bridge’s endpoint binding behaviour is still driven by `local`, not by `topic` alone.

## Shell public transfer-manager API

## Topics published

| Topic                                                 | Payload                                            |
| ----------------------------------------------------- | -------------------------------------------------- |
| `{'cap','transfer-manager','main','meta'}`            | public interface metadata                          |
| `{'cap','transfer-manager','main','status'}`          | coarse retained shell-wide transfer-manager status |
| `{'cap','transfer-manager','main','rpc','send-blob'}` | transfer control RPC                               |

### `cap/transfer-manager/main/meta`

Current shape:

```lua
{
  owner = 'fabric',
  interface = 'devicecode.cap/transfer-manager/1',
  methods = {
    ['send-blob'] = true,
  },
}
```

The current implementation does **not** expose separate `status` or `abort` RPC topics. Those are `op` values on the single `send-blob` method topic.

### `cap/transfer-manager/main/status`

Current shape:

```lua
{
  state = 'available',
  live_links = <integer>,
  desired_links = <integer>,
}
```

This is shell-wide coarse visibility only. It does not expose per-link transfer detail.

## Request payload shape

All requests sent to `{'cap','transfer-manager','main','rpc','send-blob'}` must include:

```lua
{
  link_id = <string>,
  op = 'send_blob' | 'status' | 'abort',
  ...
}
```

The shell validates:

* `link_id` must be a non-empty string
* `op` must be one of:

  * `send_blob`
  * `status`
  * `abort`

The shell then routes the request object to the selected live link child’s transfer control mailbox.

### Shell-level failures

The shell may fail the request with:

* `missing_link_id`
* `unsupported_op`
* `no_such_link`
* the mailbox send failure reason, if the link transfer control queue rejects the request

## `send_blob`

Request shape:

```lua
{
  link_id = <string>,
  op = 'send_blob',
  source = <blob source descriptor>,
  xfer_id = <string|nil>,
  receiver = <topic|nil>,
  meta = <table|nil>,
}
```

Per-link behaviour in `transfer_mgr`:

1. reject immediately with `busy` if there is already any active transfer on the link
2. normalise `source` via `shared.blob_source.normalise_source(...)`
3. choose `xfer_id = payload.xfer_id or uuid.new()`
4. set `meta = payload.meta or {}`
5. if `payload.receiver` is a topic table and `meta.receiver` is absent, copy it into `meta.receiver`
6. send `xfer_begin`
7. wait for `xfer_ready`
8. send ordered `xfer_chunk` frames
9. send `xfer_commit`
10. wait for `xfer_done`
11. reply to the original caller only after remote completion

Success reply shape is currently:

```lua
{
  ok = true,
  xfer_id = <string>,
  size = <integer>,
  checksum = <hex string>,
}
```

If the remote side aborts, or the session generation changes, or the source fails, or the protocol fails, the original request is failed.

## `status`

Request shape:

```lua
{
  link_id = <string>,
  op = 'status',
}
```

Current reply shape from the per-link transfer manager is:

```lua
{
  ok = true,
  active = <table|nil>,
  outgoing = <table|nil>,
  incoming = <table|nil>,
}
```

Where the active snapshot, if present, contains:

```lua
{
  xfer_id = <string>,
  state = <string>,
  size = <integer>,
  offset = <integer>,
  direction = 'out' | 'in',
}
```

## `abort`

Request shape:

```lua
{
  link_id = <string>,
  op = 'abort',
  reason = <string|nil>,
}
```

The per-link transfer manager aborts the active transfer, if any, and replies with:

```lua
{ ok = true }
```

If there is no active transfer, this still succeeds with `{ ok = true }`.

## Retained topics published

## Aggregate shell topic

| Topic                | Payload                    |
| -------------------- | -------------------------- |
| `{'state','fabric'}` | aggregate `fabric.summary` |

Current payload shape:

```lua
{
  kind = 'fabric.summary',
  component = 'summary',
  ts = <monotonic seconds>,
  status = {
    desired = <integer>,
    live = <integer>,
  },
  links = {
    [<link_id>] = {
      state = <string>,
      ready = <boolean>,
      established = <boolean>,
      generation = <number|nil>,
      member_class = <string|nil>,
      link_class = <string|nil>,
      node_id = <string|nil>,
    },
  },
}
```

Important point: this aggregate summary is built from shell knowledge plus the coarse summary reported upward by each link child. It is **not** a merged view of per-link bridge or transfer subtrees.

It is republished when:

* desired links are reconciled
* a child reports a new coarse summary
* a child exits
* a desired link is respawned
* transfer-manager shell status is refreshed alongside those transitions

## Per-link retained topics

Each link child owns these retained topics:

| Topic                                         | Owner          |
| --------------------------------------------- | -------------- |
| `{'state','fabric','link', <id>, 'session'}`  | `session_ctl`  |
| `{'state','fabric','link', <id>, 'bridge'}`   | `rpc_bridge`   |
| `{'state','fabric','link', <id>, 'transfer'}` | `transfer_mgr` |

All per-link component payloads share the same envelope shape:

```lua
{
  kind = 'fabric.link.<component>',
  link_id = <id>,
  component = <component>,
  ts = <monotonic seconds>,
  status = { ...component-specific fields... },
}
```

### Session subtree

`session_ctl` publishes:

```lua
{
  kind = 'fabric.link.session',
  link_id = <id>,
  component = 'session',
  ts = <monotonic seconds>,
  status = {
    state = 'down' | 'establishing' | 'ready',
    local_sid = <string>,
    peer_sid = <string|nil>,
    peer_node = <string|nil>,
    generation = <integer>,
    last_rx_at = <number|nil>,
    last_tx_at = <number|nil>,
    last_pong_at = <number|nil>,
    established = <boolean>,
    ready = <boolean>,
  },
}
```

### Bridge subtree

`rpc_bridge` publishes:

```lua
{
  kind = 'fabric.link.bridge',
  link_id = <id>,
  component = 'bridge',
  ts = <monotonic seconds>,
  status = {
    ready = <boolean>,
    replay_pending = <integer>,
    pending_calls = <integer>,
    inbound_helpers = <integer>,
    session_generation = <integer>,
    peer_sid = <string|nil>,
    established = <boolean>,
  },
}
```

Here, `ready` means the bridge has completed retained replay for the current session. This is **bridge readiness**, not overall link readiness.

### Transfer subtree

`transfer_mgr` publishes:

* when idle:

```lua
{
  kind = 'fabric.link.transfer',
  link_id = <id>,
  component = 'transfer',
  ts = <monotonic seconds>,
  status = {
    state = 'idle',
  },
}
```

* when active:

```lua
{
  kind = 'fabric.link.transfer',
  link_id = <id>,
  component = 'transfer',
  ts = <monotonic seconds>,
  status = {
    state = <string>,
    xfer_id = <string>,
    direction = 'out' | 'in',
    size = <integer>,
    offset = <integer>,
    checksum = <hex string>,
  },
}
```

## Raw provenance-bearing topics published by the child

In addition to `state/fabric/...`, `session_ctl` publishes provenance-bearing raw source topics:

| Topic                                           | Payload                      |
| ----------------------------------------------- | ---------------------------- |
| `{'raw', <kind>, <source>, 'meta'}`             | raw source identity metadata |
| `{'raw', <kind>, <source>, 'status'}`           | coarse raw source status     |
| `{'raw', <kind>, <source>, 'state', 'session'}` | exported session snapshot    |

### Raw source meta

```lua
{
  kind = <raw_kind>,
  source = <raw_source>,
  link_id = <link_id>,
  link_class = <string|nil>,
  member_class = <string|nil>,
  node_id = <string|nil>,
}
```

### Raw source status

```lua
{
  state = 'down' | 'establishing' | 'ready',
  ready = <boolean>,
  established = <boolean>,
  generation = <integer>,
  peer_node = <string|nil>,
}
```

### Raw source state/session

```lua
{
  down = <boolean>,
  local_sid = <string>,
  peer_sid = <string|nil>,
  peer_node = <string|nil>,
  generation = <integer>,
  last_rx_at = <number|nil>,
  last_tx_at = <number|nil>,
  last_pong_at = <number|nil>,
  established = <boolean>,
  ready = <boolean>,
  state = 'down' | 'establishing' | 'ready',
}
```

## Link lifecycle

The shell maintains:

* `desired[link_id]` from config
* `links[link_id]` for live children
* `restart_at[link_id]` for scheduled restarts

### Reconcile behaviour

When config is reconciled:

* a new desired link is spawned immediately
* a changed desired link causes the live child to be cancelled with reason `config_changed`
* a removed desired link causes the live child to be cancelled with reason `config_removed` and clears restart state

### Child exit behaviour

When a child exits:

* the live link record is removed
* the child scope is joined
* if the link is still desired, a restart time is scheduled using:

  * `cfg.restart_backoff_s`
  * or `2.0` seconds by default
* if the link is no longer desired, restart state is cleared
* aggregate summary is republished

The shell does not itself reopen a failed child transport in place. It restarts the whole child scope.

## Session control

`session_ctl` owns:

* handshake state
* liveness state
* session generation
* retained session subtree
* raw source publication for the link

Important invariant:

```lua
ready == (established and rpc_ready)
```

where `rpc_ready` is emitted by `rpc_bridge` over the child status mailbox.

### Derived public session state

The derived public state is:

* `down` when the link is down
* `ready` when the link is established and RPC-ready
* `establishing` otherwise

### Handshake behaviour

* before establishment, `hello` frames are sent every `hello_interval_s` defaulting to `2.0`
* once established, `ping` frames are sent every `ping_interval_s` defaulting to `10.0`
* if liveness deadlines are exceeded, the child errors:

  * `peer_liveness_timeout`
  * or `peer_pong_timeout`

If a new peer session id appears after a previous peer session id was already known, the session generation is bumped and readiness is cleared until bridge replay is complete again.

## Bridge behaviour

`rpc_bridge` owns per-link publish and call bridging.

It is responsible for:

* exporting selected local non-retained publishes to remote `pub`
* exporting selected local retained facts to remote retained `pub`
* importing remote `pub` into local publish/retain
* importing remote `unretain` into local unretain
* binding configured local outbound call endpoints and converting them to remote `call`
* handling inbound remote `call` requests via bounded helper fibres
* timing out pending outbound calls
* invalidating imported retained facts on session generation change
* publishing retained bridge state under `state/fabric/link/<id>/bridge`
* emitting `rpc_ready` to `session_ctl`

### Important bridge invariants

* pending outbound calls are failed with `session_reset` when session generation changes
* imported retained facts for the link are unretained locally when session generation changes
* imported retained facts are also unretained when matching remote `unretain` arrives
* bridge readiness is defined as:

```lua
replay_pending == 0
```

That is what is sent to `session_ctl` as `rpc_ready`.

### Inbound remote call behaviour

If inbound helper capacity is exhausted, the remote caller receives:

```lua
{ ok = false, err = 'busy' }
```

If no inbound route exists, the remote caller receives:

```lua
{ ok = false, err = 'no_route' }
```

## Transfer behaviour

`transfer_mgr` owns one link’s object transfer state.

It is responsible for:

* outgoing and incoming transfer protocol state
* transfer phase timeouts
* reset on session generation change
* progress/state publication under `state/fabric/link/<id>/transfer`
* explicit abort

### Important invariant

There is at most **one active transfer per link total**.

That active transfer may be outgoing or incoming, but not both at once.

### Outgoing protocol

Outgoing send follows this wire sequence:

1. `xfer_begin`
2. wait `xfer_ready`
3. send ordered `xfer_chunk`
4. send `xfer_commit`
5. wait `xfer_done`
6. reply success to the original local caller

### Incoming protocol

Incoming receive follows this wire sequence:

1. accept `xfer_begin`
2. open a sink via `ctx.open_incoming_sink(...)`, or use the default memory sink
3. send `xfer_ready`
4. accept ordered `xfer_chunk`
5. send `xfer_need` after each accepted chunk
6. on `xfer_commit`, verify size and checksum
7. commit the sink
8. if `meta.receiver` is a topic table, call that local receiver endpoint with the committed artefact
9. on success, send `xfer_done`

If the receiver call fails, the artefact is deleted and the remote side is aborted.

### Abort behaviour

An explicit `abort` request, protocol error, checksum mismatch, sink failure, source failure, timeout, or session generation change clears the active transfer.

For outgoing transfers, the original local request is failed.

For incoming transfers, the sink is aborted if it supports `abort()`.

## Internal ownership summary

* `fabric.lua`
  shell reconcile, restart policy, aggregate summary, public transfer-manager interface

* `session.lua`
  one live link child scope

* `session_ctl.lua`
  handshake, readiness, liveness, raw source publication, session retained subtree

* `rpc_bridge.lua`
  publish bridging, call bridging, retained replay, pending call bookkeeping, bridge retained subtree

* `transfer_mgr.lua`
  per-link transfer protocol, per-link transfer retained subtree

* `reader.lua` / `writer.lua`
  framed I/O only
