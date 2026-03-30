# Time Service

## Description

The time service listens to time capabilities for sync and unsync events. It uses the events to sync and unsync the alarm module of fibers and broadcast sync/unsync events to the bus for other services to listen to.

## Time capability

There is initially only one time capability, provided by the time driver in HAL. In the future we can discover multiple time capabilities and balance multiple sources of time intelligently (e.g. prefer the capability reporting the lowest stratum).

For now, the time service subscribes to `{'cap', 'time', '+', 'meta', 'source'}` and uses the **first** capability announced. Subsequent announcements are ignored.

## Bus Outputs

### Service status (retained)

Topic: `{'svc', 'time', 'status'}`

```lua
{
  state = 'starting' | 'running' | 'synced' | 'unsynced' | 'stopped',
  ts    = <number>,
}
```

The `state` field doubles as the authoritative sync signal: it transitions to `'synced'` or `'unsynced'` on every sync state change. It is retained so services that start later immediately receive the current state.

### Time transition events (non-retained)

Topics:
- `{'obs', 'event', 'time', 'synced'}`
- `{'obs', 'event', 'time', 'unsynced'}`

Published on state transitions for consumers that need edge-triggered behaviour.

## Service Flow

```mermaid
flowchart TD
  St[Start] --> B(Publish status: starting)
  B --> C(Subscribe to cap/time/+/meta/source)
  C --> D(Publish status: running)
  D --> E{Wait for first time capability meta message or scope done}
  E -->|scope done| Z[Publish status: stopped]
  E -->|first capability meta received| F(Extract uuid from meta topic)
  F --> G(Subscribe to cap/time/uuid/state/synced\ncap/time/uuid/event/synced\ncap/time/uuid/event/unsynced)
  G --> H(Read single retained state message and apply sync state)
  H --> H2(Unsubscribe from state/synced)
  H2 --> K{Wait for synced event, unsynced event, or scope done}
  K -->|synced event| L(Apply synced: set status=synced, emit obs/event/time/synced)
  L --> K
  K -->|unsynced event| M(Apply unsynced: set status=unsynced, emit obs/event/time/unsynced)
  M --> K
  K -->|scope done| Z
```

All three subscriptions are created before any message is read, so no events are lost during initialisation. The retained `{'cap', 'time', <uuid>, 'state', 'synced'}` payload is consumed as a one-shot read to bootstrap sync state, then the state subscription is dropped. Ongoing sync state changes are tracked exclusively through the `event/synced` and `event/unsynced` transition topics.

With the new fibers alarm API, the service calls:
- `alarm.set_time_source(fibers.utils.time.realtime)` on first synced state
- `alarm.time_changed()` on subsequent synced transitions/events

There is no direct equivalent of `clock_desynced` in the new API; unsynced updates still propagate over bus outputs.

## Architecture

- Everything runs in a single fiber — no child fibers needed. The fiber blocks waiting for the first capability, then transitions directly into the event loop for that capability.
- The service does not interact with the OS directly — all time source information arrives through the capability published by the time driver in HAL.
- Use `finally` to log shutdown reason and publish `stopped` status.

