# Fabric Service

## Purpose

The Fabric service supervises local peer/member links.
It owns:

1. retained `cfg/fabric` consumption
2. desired-vs-live link supervision
3. aggregate retained summary under `state/fabric`
4. a service-level transfer RPC that routes requests to the correct live link child

Each live link runs in its own child scope. The child owns:
- transport open/close
- handshake, readiness and liveness
- local/remote publish bridging
- local/remote RPC bridging
- blob/object transfer

The shell keeps restart policy and aggregate visibility centralised while isolating link faults inside child scopes.

## Dependencies

### Retained configuration

| Topic | Purpose |
|---|---|
| `{'cfg','fabric'}` | Desired link configuration. Retained and replayed on startup. |

### Transport opening

The shell does not open transports itself. Each link child resolves and opens its transport through the session runtime.

Supported transport forms are:
- a supplied `cfg.transport.open` function
- or a HAL-backed transport opened from `cfg.transport.class` / `cfg.transport.id`

The returned transport must behave like a `fibers` stream.

### Service-level command endpoint

| Topic | Purpose |
|---|---|
| `{'cmd','fabric','transfer'}` | Route one transfer control request to a live link child. |

## Configuration

The service accepts either:
- `payload.data.links`
- or a top-level table of link records

Each link record is normalised with:
- `id = v.id or v.link_id or key`

Effective link config shape:

```lua
{
  links = {
    [<link_id>] = {
      id = <string>,
      node_id = <string|nil>,
      member_class = <string|nil>,
      link_class = <string|nil>,

      restart_backoff_s = <number|nil>,

      transport = {
        class = <string|nil>,
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

### Topic-map rules

Topic rules are normalised by `services.fabric.topicmap`.

Accepted fields are:

```lua
{
  id = <string|nil>,
  local = { ... } | nil,
  remote = { ... } | nil,
  topic = { ... } | nil,
  timeout = <number|nil>,
}
```

Legacy aliases such as `local_prefix`, `remote_prefix`, `from`, `to` and similar are rejected.

Semantics:
- `export_publish_rules`: local non-retained publish -> remote `pub retain=false`
- `export_retained_rules`: local retained watch -> remote `pub retain=true`
- `import_rules`: remote `pub` / `unretain` -> local publish / retain / unretain
- `outbound_call_rules`: local bound endpoint -> remote `call`
- `inbound_call_rules`: remote `call` -> local bus call

Exact-topic rules are supported with `topic = {...}` and are checked before broader prefix replacement.

## Exposed command API

### `cmd/fabric/transfer`

Request payload must include:

```lua
{
  link_id = <string>,
  op = 'send_blob' | 'status' | 'abort',
  ...
}
```

The shell validates `link_id`, resolves the live link, and forwards the whole request object to that link child’s transfer mailbox.

Shell-level failures:
- `missing_link_id`
- `unsupported_op`
- `no_such_link`
- any mailbox send failure reason from the link queue

### `send_blob`

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

The link child transfer manager:
1. normalises the source via `blob_source.normalise_source`
2. sends `xfer_begin`
3. waits for `xfer_ready`
4. streams ordered chunks
5. sends `xfer_commit`
6. waits for `xfer_done`
7. replies to the original caller only after remote completion

Success replies are transfer-manager defined, typically including `ok`, `xfer_id`, `size`, `checksum`, and receiver-specific result fields.

### `status`

```lua
{ link_id = <string>, op = 'status' }
```

Returns the transfer manager’s current coarse status snapshot for that link.

### `abort`

```lua
{ link_id = <string>, op = 'abort', reason = <string|nil> }
```

Aborts any live incoming and outgoing transfer for the link and replies with `{ ok = true }`.

## Retained topics published

### Aggregate shell topic

| Topic | Payload |
|---|---|
| `{'state','fabric'}` | aggregate `fabric.summary` |

Payload shape:

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

This summary is republished whenever desired links change, a child reports a new summary, a child exits, or a desired link is restarted.

### Per-link retained topics

Each live child owns its own retained subtree:

| Topic | Owner |
|---|---|
| `{'state','fabric','link', <id>, 'session'}` | `session_ctl` |
| `{'state','fabric','link', <id>, 'bridge'}` | `rpc_bridge` |
| `{'state','fabric','link', <id>, 'transfer'}` | `transfer_mgr` |

All per-link component payloads share the same envelope style:

```lua
{
  kind = 'fabric.link.<component>',
  link_id = <id>,
  component = <component>,
  ts = <monotonic seconds>,
  status = { ...component-specific fields... },
}
```

## Link lifecycle

The shell maintains:
- `desired[link_id]` from config
- `links[link_id]` for live children
- `restart_at[link_id]` for backoff-based restarts

Config reconcile behaviour:
- new desired link -> spawn child
- changed desired link -> stop live child and let it restart with new config
- removed desired link -> stop child and clear restart state

On child exit:
- the live link record is removed
- the child scope is joined
- if the link is still desired, a restart time is scheduled using `restart_backoff_s` or `2.0` seconds by default
- the aggregate summary is republished

## Session control

`session_ctl` owns the session retained subtree and derives:
- `down`
- `established`
- `ready`
- `generation`
- peer identity fields such as `peer_sid` and `peer_node`
- liveness timestamps (`last_rx_at`, `last_tx_at`, `last_pong_at`)

Important invariant:
- `ready == (established and rpc_ready)`

The derived public session state is:
- `'down'` when the link is down
- `'ready'` when the link is established and RPC-ready
- `'establishing'` otherwise

## Bridge behaviour

`rpc_bridge` owns topic bridging for one live link.

It is responsible for:
- exporting local publishes to remote `pub`
- exporting local retained state to remote retained `pub`
- importing remote publishes/unretains to local publish/retain/unretain
- exporting local call endpoints to remote `call`
- handling inbound remote `call` requests against configured local topics
- publishing retained bridge status under the per-link `bridge` topic

Imported retained topics are explicitly unretained locally when a matching remote `unretain` arrives.

## Transfer behaviour

`transfer_mgr` owns one live link’s object-transfer state.

It is responsible for:
- outgoing and incoming transfer state machines
- xfer begin / ready / chunk / commit / done handling
- progress/state publication under the per-link `transfer` topic
- explicit abort of both directions

The shell does not interpret transfer protocol details; it only routes requests to the correct live link.
