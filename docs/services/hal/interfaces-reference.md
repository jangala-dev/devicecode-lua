# HAL Interfaces Reference

This reference defines the core HAL message and capability interfaces used by managers and drivers.

## ControlRequest

Constructor: `hal_types.new.ControlRequest(verb, opts, reply_ch)`

Fields:

- `verb` string
- `opts` table
- `reply_ch` Channel

Invariants:

- `verb` MUST be a non-empty string.
- `opts` MUST be a table.
- `reply_ch` MUST be a fibers channel.

Source: `src/services/hal/types/core.lua`

## Reply

Constructor: `hal_types.new.Reply(ok, reason, code)`

Fields:

- `ok` boolean
- `reason` any
- `code` integer optional

Invariants:

- `ok` MUST be boolean.
- Drivers SHOULD provide a non-empty reason on failure.

Outcome semantics:

- On failure (`ok == false`), `reason` SHOULD contain an error string and optional `code`.
- On success (`ok == true`), `reason` MAY carry a direct endpoint outcome value.
- Query endpoints (for example modem `get`) SHOULD return their value directly rather than only boolean success.

Source: `src/services/hal/types/core.lua`

## Emit

Constructor: `hal_types.new.Emit(class, id, mode, key, data)`

Fields:

- `class` capability class
- `id` capability id
- `mode` one of `event`, `state`, `meta`, `log`
- `key` non-empty string
- `data` non-nil value

Invariants:

- `mode` MUST be one of the supported values.
- `data` MUST NOT be nil.

Source: `src/services/hal/types/core.lua`

## DeviceEvent

Constructor: `hal_types.new.DeviceEvent(event_type, class, id, meta, capabilities)`

Fields:

- `event_type` one of `added`, `removed`
- `class` device class
- `id` device id
- `meta` table
- `capabilities` array of Capability

Invariants:

- `event_type` MUST be `added` or `removed`.
- `capabilities` MUST contain only Capability typed objects.

Source: `src/services/hal/types/core.lua`

## Capability

Constructor: `cap_types.new.Capability(class, id, control_ch, offerings)`

Fields:

- `class` string
- `id` string or non-negative integer
- `control_ch` Channel
- `offerings` map of supported verbs

Invariants:

- Offerings input MUST be array of non-empty strings.
- `control_ch` MUST be a fibers channel.
- Offerings SHOULD be stable for the device lifetime.

Typed constructors include:

- `new.ModemCapability(id, control_ch)`
- `new.FilesystemCapability(id, control_ch)`
- `new.UARTCapability(id, control_ch)`

Source: `src/services/hal/types/capabilities.lua`

## Capability Args Pattern

Options objects are typed by metatable and validated by constructor helpers.

Examples:

- `capability_args.new.ModemGetOpts(field, timescale)`
- `capability_args.new.ModemConnectOpts(connection_string)`
- `capability_args.new.FilesystemReadOpts(filename)`
- `capability_args.new.FilesystemWriteOpts(filename, data)`

Invariants:

- Driver verb handlers MUST validate expected metatable type.
- Callers SHOULD always construct opts using the exported constructor helpers.

Source: `src/services/hal/types/capability_args.lua`

## Channel Contracts

Manager channels:

- `dev_ev_ch` carries `DeviceEvent` add/remove lifecycle announcements.
- `cap_emit_ch` carries `Emit` messages sourced by drivers.
- Internal detection/removal/driver-ready channels MAY be manager-specific implementation details.

Manager interface requirement:

- Every manager MUST expose `start(logger, dev_ev_ch, cap_emit_ch)`, `stop(timeout)`, and `apply_config(config)`.
- `apply_config(config)` MAY be a no-op when runtime configuration is not used, but the endpoint MUST exist.

Driver channels:

- Capability `control_ch` receives `ControlRequest`.
- `reply_ch` embedded in each `ControlRequest` receives `Reply`.
- `cap_emit_ch` is the outbound channel for `Emit`.

Capability channels:

- Every capability object MUST expose a valid fibers `control_ch`.
- Clients call capabilities by writing `ControlRequest` to capability `control_ch`.

## Extension Point Index

Manager extension points:

- detector loop and event routing in `src/services/hal/managers/modemcard.lua`

Driver extension points:

- verb methods and control loop in `src/services/hal/drivers/modem.lua`
- backend-free verb methods in `src/services/hal/drivers/filesystem.lua`

Backend extension points:

- provider selection and assembly in `src/services/hal/backends/modem/provider.lua`
- contract validation in `src/services/hal/backends/modem/contract.lua`
- mode augmentation in `src/services/hal/backends/modem/modes/qmi.lua`
- model augmentation in `src/services/hal/backends/modem/models/quectel.lua`
