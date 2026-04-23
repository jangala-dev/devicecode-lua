# Fabric Service

## Purpose

The Fabric service supervises in-process peer links.
It owns:

1. retained `cfg/fabric` consumption
2. desired-vs-live link supervision
3. aggregate retained summary under `state/fabric`
4. a service-level transfer RPC that routes requests to the correct live link child

Each live link runs in its own child scope. The child owns:

- transport open/close
- handshake and liveness
- RPC / retained bridging
- blob transfer

This keeps restart policy and aggregate visibility in the shell while isolating link faults inside child scopes.

## Dependencies

### Retained configuration

| Topic | Purpose |
|---|---|
| `{'cfg','fabric'}` | Desired link configuration. Retained and replayed on startup. |

### Transport opening

The shell does not talk to HAL directly. Each link child opens its transport through `services.fabric.transport_uart` unless a custom transport factory is supplied in config.

Default transport selection uses a HAL capability via `cap_sdk` with:

| Transport class | Id selection |
|---|---|
| `uart` (default) | `cfg.transport.id` or `link_id` |

By default the transport control verb is `open`, and the returned object must behave like a `fibers` stream.

### Service-level command endpoint

| Topic | Purpose |
|---|---|
| `{'cmd','fabric','transfer'}` | Route one transfer control request to a link child. |

## Configuration

The service accepts either:

- `payload.data.links`
- or a top-level table of link records

Each link record is normalised with `id = v.id or v.link_id or key`.

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

`services.fabric.topicmap` normalises declarative prefix rules. Accepted fields include:

```lua
{
  id = <string|nil>,
  local = { ... } | nil,
  remote = { ... } | nil,
  local_prefix = { ... } | nil,
  remote_prefix = { ... } | nil,
  from = { ... } | nil,
  to = { ... } | nil,
  topic = { ... } | nil,
  timeout = <number|nil>,
}
```

Semantics:

- `export_publish_rules`: local non-retained pub/sub -> remote `pub retain=false`
- `export_retained_rules`: local retained watch -> remote `pub retain=true`
- `import_rules`: remote `pub` / `unretain` -> local publish / retain / unretain
- `outbound_call_rules`: local bound endpoint -> remote `call`
- `inbound_call_rules`: remote `call` -> local bus call

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

Failures at the shell level:

- `invalid_link_id`
- `unknown_transfer_op`
- `link_not_live`
- `transfer_request_rejected`

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

The link child:

1. normalises the source via `blob_source.normalise_source`
2. sends `xfer_begin`
3. waits for `xfer_ready`
4. streams ordered chunks
5. sends `xfer_commit`
6. waits for `xfer_done`
7. replies to the original caller only after remote completion

On success the final reply payload is whatever the transfer manager returned, typically including:

```lua
{
  ok = true,
  xfer_id = <string>,
  size = <integer>,
  checksum = <string|nil>,
}
```

### `status`

```lua
{ link_id = <string>, op = 'status' }
```

Returns a coarse snapshot such as:

```lua
{
  ok = true,
  link_id = <string>,
  outgoing = <table|nil>,
  incoming = <table|nil>,
}
```

### `abort`

```lua
{ link_id = <string>, op = 'abort', reason = <string|nil> }
```

Aborts any live incoming and outgoing transfer for the link and replies with:

```lua
{ ok = true }
```

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

All of these payloads use the common envelope produced by `statefmt.link_component(...)`:

```lua
{
  kind = 'fabric.link.<component>',
  link_id = <id>,
  component = <component>,
  ts = <monotonic seconds>,
  status = { ... },
}
```

## Link child responsibilities

### Session control

`session_ctl` owns `state/fabric/link/<id>/session`.

Responsibilities:

- generate and retain `local_sid`
- exchange `hello`, `hello_ack`, `ping`, `pong`
- track `peer_sid`, `peer_node`, and handshake generation
- track last RX/TX/PONG timestamps
- maintain `established` and `ready`
- detect liveness timeout
- publish coarse summary updates upward to the shell

Retained session status shape:

```lua
{
  state = 'opening' | 'establishing' | 'ready' | 'down',
  local_sid = <string>,
  peer_sid = <string|nil>,
  peer_node = <string|nil>,
  generation = <number>,
  last_rx_at = <number|nil>,
  last_tx_at = <number|nil>,
  last_pong_at = <number|nil>,
  established = <boolean>,
  ready = <boolean>,
}
```

`ready` is only true once both hold:

- the session is established
- the RPC bridge has reported itself ready for the current generation

### RPC bridge

`rpc_bridge` owns `state/fabric/link/<id>/bridge`.

Responsibilities:

- subscribe to local non-retained export topics
- watch local retained export topics
- bind local outbound call helpers
- translate remote `pub`, `unretain`, `call`, and `reply` frames
- maintain pending outbound calls and helper counts
- replay retained exports after a fresh session establishment

Retained bridge status shape:

```lua
{
  ready = <boolean>,
  replay_pending = <integer>,
  pending_calls = <integer>,
  inbound_helpers = <integer>,
  session_generation = <number>,
  peer_sid = <string|nil>,
  established = <boolean>,
}
```

### Transfer manager

`transfer_mgr` owns `state/fabric/link/<id>/transfer`.

Responsibilities:

- manage at most one outgoing transfer and one incoming transfer per link
- normalise outgoing sources
- send and receive ordered chunked data
- verify incoming size/checksum
- commit incoming sink to an artefact
- optionally call a local receiver topic after commit
- abort transfers on timeout, reset, or session generation change

Outgoing flow:

1. accept `send_blob`
2. normalise source
3. send `xfer_begin`
4. wait for `xfer_ready`
5. send ordered `xfer_chunk` frames
6. send `xfer_commit`
7. wait for `xfer_done`
8. reply `{ ok = true, xfer_id, size, checksum }`

Incoming flow:

1. accept `xfer_begin`
2. open a sink (`memory_sink` by default if no sink factory is supplied)
3. send `xfer_ready`
4. accept ordered `xfer_chunk` frames
5. send `xfer_need` after each accepted chunk
6. on `xfer_commit`, verify size and checksum
7. commit the sink to an artefact
8. if `meta.receiver` is a topic, call it with `{ link_id, xfer_id, size, checksum, meta, artefact }`
9. send `xfer_done`

Retained transfer status is coarse but enough for observability. It always includes `state`, and when a transfer is active or complete it may also include:

- `xfer_id`
- `direction` (`'in'` or `'out'`)
- `size`
- `offset`
- `checksum`
- `err`

The transfer topic is unretained when the manager stops.

## Reader / writer scheduling

### Reader

The reader:

- reads line-delimited frames from the transport
- decodes them with `protocol.decode_line`
- routes them to the control, RPC, or transfer mailboxes
- reports RX activity to session control

Bad frames are tolerated up to:

- `bad_frame_limit` within `bad_frame_window_s`

If that threshold is exceeded, the reader faults the link child.

### Writer

The writer:

- consumes pre-encoded writer items from three queues: control, rpc, bulk
- always prioritises control traffic
- uses weighted round-robin between RPC and bulk traffic with `rpc_quantum` and `bulk_quantum`
- writes line-delimited encoded frames to the transport
- reports TX activity to session control

## Protocol classes

All wire frames are JSON-encoded line-delimited objects.

### Control frames

- `hello`
- `hello_ack`
- `ping`
- `pong`
- `xfer_begin`
- `xfer_ready`
- `xfer_need`
- `xfer_commit`
- `xfer_done`
- `xfer_abort`

### RPC / pub-sub frames

- `pub`
- `unretain`
- `call`
- `reply`

### Bulk frames

- `xfer_chunk`

## Shell flow

1. watch retained `cfg/fabric`
2. bind `cmd/fabric/transfer`
3. normalise desired links
4. spawn new links, stop changed links, remove missing links
5. publish aggregate `state/fabric`
6. route transfer requests to the target link child
7. consume child summary reports
8. consume child exit reports and schedule restart when still desired
9. respawn desired links after `restart_backoff_s`

## Link child flow

1. open transport
2. allocate control, RPC, transfer, and writer mailboxes
3. spawn reader
4. spawn writer
5. spawn session control
6. spawn RPC bridge
7. spawn transfer manager
8. exit the child scope on fault or cancellation

## Architecture notes

- the shell owns desired links, live link bookkeeping, and restart policy
- each link child owns everything below the aggregate state line
- link faults are isolated to child scopes; the shell decides whether to restart
- retained state is best-effort and monotonic-time stamped
- the default transport contract is a `fibers` stream opened through HAL, but a custom transport factory can be injected per link
- transfer delivery to a local receiver topic happens after sink commit, so receivers work with artefacts rather than raw chunks
