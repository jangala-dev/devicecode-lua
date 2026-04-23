# Radio Driver (HAL)

## Description

The Radio Driver is a HAL component that exposes wireless radio configuration and interface statistics to the rest of the system via a single `radio` capability. It:

1. **Holds staged configuration** — all `set_*` calls accumulate changes in-memory. Changes are not applied until `apply()` is called.
2. **Applies staged config on demand** — `apply()` delegates the staged config table to the active backend, which is responsible for writing it to the underlying OS config system (e.g. UCI) and triggering a reload.
3. **Emits interface stats** — a stats loop calls backend methods to detect client connect/disconnect events and collect per-interface counters, emitting them via the capability `emit_ch` for HAL to publish on the bus.

The driver never touches UCI or any OS config system directly. All config writes are delegated to the active backend via `backend:apply(staged)`. A future non-OpenWrt backend can implement the same backend interface without any UCI involvement.

## Dependencies

- `backends/radio/provider.lua` — selects the active backend at driver creation.

## Initialisation

On creation by the WLAN Manager:

1. Resolve the radio backend via `provider.get_backend()`. If no supported backend is found, creation fails with an error; the manager logs the error and does not emit a device-added event.
2. Fetch initial radio metadata via `backend:get_meta(name)` to populate the capability meta (path, type).
3. Initialise the staged config table (empty).
4. Publish capability `meta`.
5. Start the RPC handler fiber.
6. Start the stats loop fiber.

## Capability

Class: `radio`
Id: UCI radio section name (e.g. `'radio0'`, `'radio1'`)

### Meta (retained)

Topic: `{'cap', 'radio', <id>, 'meta'}`

```lua
{
  provider = 'hal',
  version  = 1,
  name     = <string>,   -- UCI radio section name
  path     = <string>,   -- PCI/AHB device path, e.g. "platform/ahb/18100000.wmac"
  type     = <string>,   -- radio chipset type, e.g. "mac80211"
}
```

### Offerings

All offerings return `{ ok = true }` on success or `{ ok = false, reason = <string> }` on validation failure or internal error.

---

#### set_channels

Topic: `{'cap', 'radio', <id>, 'rpc', 'set_channels'}`

Stages the radio frequency parameters in the driver's staged config. No UCI write occurs until `apply` is called.

Input:

```lua
{
  band     = <string>,         -- required: "2g" or "5g"
  channel  = <number|string>,  -- required: channel number or "auto"
  htmode   = <string>,         -- required: one of "HE20","HE40+","HE40-","HE80","HE160","HT20","HT40+","HT40-","VHT20","VHT40+","VHT40-","VHT80","VHT160"
  channels = <table|nil>,      -- required when channel == "auto": list of numbers or strings
}
```

Validation:
- `band` must be `"2g"` or `"5g"`.
- `htmode` must be one of the listed valid values.
- When `channel == "auto"`, `channels` must be a non-empty list of numbers or strings.
- When `channel ~= "auto"`, `channel` must be a number or string.

---

#### set_txpower

Topic: `{'cap', 'radio', <id>, 'rpc', 'set_txpower'}`

Input:

```lua
{
  txpower = <number|string>,  -- required
}
```

Validation: `txpower` must be a number or a string.

---

#### set_country

Topic: `{'cap', 'radio', <id>, 'rpc', 'set_country'}`

Input:

```lua
{
  country = <string>,  -- required: 2-letter ISO country code (normalised to uppercase)
}
```

Validation: must be a 2-character string.

---

#### set_enabled

Topic: `{'cap', 'radio', <id>, 'rpc', 'set_enabled'}`

Input:

```lua
{
  enabled = <boolean>,  -- required
}
```

Stages the enabled/disabled state for the radio. Validation: must be boolean.

---

#### add_interface

Topic: `{'cap', 'radio', <id>, 'rpc', 'add_interface'}`

Stages a new wireless interface entry for this radio. The interface name is generated as `<radio_name>_i<N>` where N is an auto-incrementing counter.

Input:

```lua
{
  ssid           = <string>,   -- required: SSID string, non-empty
  encryption     = <string>,   -- required: one of "none","wep","psk","psk2","psk-mixed","sae","sae-mixed","owe","wpa","wpa2","wpa3"
  password       = <string>,   -- required: may be empty string for open networks
  network        = <string>,   -- required: network interface name, non-empty
  mode           = <string>,   -- required: one of "ap","sta","adhoc","mesh","monitor"
  enable_steering = <boolean>, -- required: if true, enables 802.11k/v BSS transition flags
}
```

Reply on success:

```lua
{ ok = true, result = <string> }  -- result is the generated interface name e.g. "radio0_i0"
```

When `enable_steering = true`, the staged interface entry includes BSS transition and 802.11k flags. The backend is responsible for mapping these to the appropriate config system keys (e.g. `bss_transition`, `ieee80211k`, `rrm_neighbor_report`, `rrm_beacon_report` in UCI).

---

#### delete_interface

Topic: `{'cap', 'radio', <id>, 'rpc', 'delete_interface'}`

Marks an interface entry for removal in the staged config. The removal is applied by the backend on the next `apply` call.

Input:

```lua
{
  interface = <string>,  -- required: interface name to delete, non-empty
}
```

---

#### clear_radio_config

Topic: `{'cap', 'radio', <id>, 'rpc', 'clear_radio_config'}`

Resets the in-memory staged config to the base state: only the radio's fixed identity fields (`name`, `path`, `type`). All previously staged option changes and all staged interface entries are discarded. No backend call is made — this is a purely in-memory operation.

Input: none (empty object `{}`).

---

#### set_report_period

Topic: `{'cap', 'radio', <id>, 'rpc', 'set_report_period'}`

Sets the metrics loop publish interval. Takes effect on the next sleep in the metrics loop.

Input:

```lua
{
  period = <number>,  -- required: interval in seconds, must be > 0
}
```

---

#### apply

Topic: `{'cap', 'radio', <id>, 'rpc', 'apply'}`

Passes the full staged config table to `backend:apply(staged)`. The backend is responsible for writing to UCI (or equivalent) and triggering a reload. The backend coalesces rapid successive reloads with a 1-second debounce window.

Input: none (empty object `{}`).

On success, the per-interface counter is reset so future `add_interface` calls start from `_i0` again.

---

#### rollback

Topic: `{'cap', 'radio', <id>, 'rpc', 'rollback'}`

Discards all staged changes. The staged config is reset to the same state as after `clear_radio_config` was last called. No backend call is made.

Input: none (empty object `{}`).

---

## Stats Loop

The stats loop runs in a separate fiber within the driver's scope. It calls backend methods to monitor client connect/disconnect events and to collect per-interface counters on each report period tick. All results are emitted via `emit_ch` as `Emit` values — HAL reads them and publishes them on the bus under `cap/radio/<id>/state/<name>` and `cap/radio/<id>/event/<name>`. The wifi service subscribes to these topics to perform session management, MAC hashing, and observability publishing. The driver is not aware of any of that logic.

### Client events

The backend monitors the wireless interface for `AP-STA-CONNECTED` and `AP-STA-DISCONNECTED` events (using `iw event` on OpenWrt). For each event the driver emits a raw `client_event` with the MAC address and connection state. The wifi service handles session ID generation, MAC address hashing, and deduplication.

### Emitted stats

Stats are refreshed on each `report_period` tick. All values are emitted via `emit_ch` for HAL to publish.

| Emit key             | Content                                            | Source                                      |
|----------------------|----------------------------------------------------|---------------------------------------------|
| `client_event`       | `{ mac, connected, interface, timestamp }`         | backend event monitor (e.g. `iw event`)     |
| `num_sta`            | Total connected station count (number)             | Derived from connect/disconnect tracking    |
| `iface_num_sta`      | `{ interface, band, index, count }`                | Per-interface station count                 |
| `iface_txpower`      | `{ interface, value }`                             | backend query (e.g. `iw dev <iface> info`)  |
| `iface_channel`      | `{ interface, channel, freq, width }`              | backend query (e.g. `iw dev <iface> info`)  |
| `iface_noise`        | `{ interface, value }`                             | backend query (e.g. `iw <iface> survey dump`) |
| `iface_rx_bytes`     | `{ interface, value }`                             | `/sys/class/net/<iface>/statistics/`        |
| `iface_tx_bytes`     | `{ interface, value }`                             | `/sys/class/net/<iface>/statistics/`        |
| `iface_rx_packets`   | `{ interface, value }`                             | `/sys/class/net/<iface>/statistics/`        |
| `iface_tx_packets`   | `{ interface, value }`                             | `/sys/class/net/<iface>/statistics/`        |
| `iface_rx_dropped`   | `{ interface, value }`                             | `/sys/class/net/<iface>/statistics/`        |
| `iface_tx_dropped`   | `{ interface, value }`                             | `/sys/class/net/<iface>/statistics/`        |
| `iface_rx_errors`    | `{ interface, value }`                             | `/sys/class/net/<iface>/statistics/`        |
| `iface_tx_errors`    | `{ interface, value }`                             | `/sys/class/net/<iface>/statistics/`        |
| `client_signal`      | `{ mac, interface, signal }`                       | backend query (e.g. `iw dev <iface> station get <mac>`) |
| `client_tx_bytes`    | `{ mac, interface, value }`                        | backend query (e.g. `iw dev <iface> station get <mac>`) |
| `client_rx_bytes`    | `{ mac, interface, value }`                        | backend query (e.g. `iw dev <iface> station get <mac>`) |

### Interface assignment

Each radio has a **fixed interface name** assigned from config (no hotplug binding). Interface names are derived from the `add_interface` sequence (e.g. `radio0_i0`, `radio0_i1`). The mapping from SSID name to interface index is built when `add_interface` is called and held in-memory by the stats loop fiber.

## Types

All capability arg and reply types follow the conventions in `src/services/hal/types/`.

### `RadioSetChannelsOpts`

```lua
---@class RadioSetChannelsOpts
---@field band string         -- "2g" or "5g"
---@field channel number|string  -- channel number or "auto"
---@field htmode string
---@field channels table|nil  -- required when channel=="auto"
```

### `RadioSetTxpowerOpts`

```lua
---@class RadioSetTxpowerOpts
---@field txpower number|string
```

### `RadioSetCountryOpts`

```lua
---@class RadioSetCountryOpts
---@field country string  -- 2-letter ISO code
```

### `RadioSetEnabledOpts`

```lua
---@class RadioSetEnabledOpts
---@field enabled boolean
```

### `RadioAddInterfaceOpts`

```lua
---@class RadioAddInterfaceOpts
---@field ssid string
---@field encryption string
---@field password string
---@field network string
---@field mode string
---@field enable_steering boolean
```

### `RadioDeleteInterfaceOpts`

```lua
---@class RadioDeleteInterfaceOpts
---@field interface string
```

### `RadioSetReportPeriodOpts`

```lua
---@class RadioSetReportPeriodOpts
---@field period number  -- seconds, > 0
```

### `RadioCapabilityReply`

```lua
---@class RadioCapabilityReply
---@field ok boolean
---@field reason string|nil  -- present on failure; on add_interface success, holds the generated interface name
```

## Backend Contract

The OpenWrt radio backend (`backends/radio/providers/openwrt/impl.lua`) must implement:

| Function           | Description                                                                                                        |
|--------------------|--------------------------------------------------------------------------------------------------------------------|
| `is_supported()`   | Returns `true` if running on OpenWrt (checks `/etc/openwrt_release`)                                              |
| `get_meta(name)`   | Returns `{ path, type }` for the radio. No config system cursor exposed to the driver.                             |
| `apply(staged)`    | Writes the staged config table to the OS config system (UCI on OpenWrt) and triggers a reload. The 1-second debounce is an internal backend concern. |
| `watch_events(interfaces, cb)` | Opens an event monitor (e.g. `iw event`) and calls `cb(event)` for each client connect/disconnect event. The driver calls this to feed the stats loop. |
| `get_iface_info(iface)` | Returns txpower, channel, frequency, and channel width for a given interface (e.g. via `iw dev info`). |
| `get_iface_survey(iface)` | Returns noise floor for a given interface (e.g. via `iw survey dump`). |
| `get_station_info(iface, mac)` | Returns per-client signal, tx_bytes, rx_bytes (e.g. via `iw station get`). |

The sysfs counters (`/sys/class/net/<iface>/statistics/`) are read directly by the driver, not the backend, as they are a standard Linux interface not specific to any wireless stack.

The driver passes the staged config table opaquely to `apply`. The backend is the only component that knows how to interpret and write it.

## Service Flow

### RPC handler fiber

1. Resolve backend; publish meta.
2. Enter `named_choice` loop on `control_ch` and scope cancellation.
3. On each RPC: validate inputs; update staged config table; reply `{ ok = true }` or `{ ok = false, reason = ... }`.
4. On `apply`: pass staged config table to `backend:apply(staged)`; reset interface counter.
5. On `rollback`: discard staged config table.
6. On scope cancelled: exit loop.

### Stats loop fiber

1. Call `backend:watch_events(interfaces, cb)` to start monitoring client connect/disconnect events.
2. Enter `named_choice` loop over: client event callback, report-period tick, new report period, scope cancelled.
3. On client event: emit `client_event` with raw MAC and state; update in-memory station count; emit `num_sta` and `iface_num_sta`.
4. On report-period tick: call `backend:get_iface_info`, `backend:get_iface_survey`, `backend:get_station_info` for each known interface; read sysfs statistics; emit all `iface_*` and `client_*` stats.
5. On new report period: update sleep timer.
6. On scope cancelled: exit; signal backend to stop event monitoring.

## Architecture

- The driver runs two concurrent fibers: the RPC handler and the stats loop. Both are children of the driver's scope.
- Staged config is a plain Lua table local to the driver; it is only ever accessed by the RPC handler fiber (no concurrent access).
- `apply` passes the staged config table to `backend:apply(staged)`. The driver has no knowledge of how the backend writes the config.
- Stats are emitted via `emit_ch` as `Emit` objects. HAL reads `emit_ch` and publishes them to the bus under `cap/radio/<id>/state/<name>` or `cap/radio/<id>/event/<name>`. The driver never publishes to the bus directly.
- All OS-specific tool calls (`iw event`, `iw dev info`, `iw survey dump`, `iw station get`) are encapsulated in the backend. The driver calls backend methods; the backend handles subprocess management, output parsing, and error recovery.
- If the event monitor subprocess exits unexpectedly, the backend is responsible for restarting it. The driver is notified via the callback mechanism and may log a warning.
- A `finally` block on the driver scope logs the reason for shutdown.
