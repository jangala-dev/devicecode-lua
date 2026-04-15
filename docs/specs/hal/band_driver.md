# Band Driver (HAL)

## Description

The Band Driver is a HAL component that exposes DAWN (Distributed Access point with No-manager) band steering daemon configuration to the rest of the system via a single `band` capability. It:

1. **Holds staged configuration** — all `set_*` calls accumulate changes in-memory. No config system is touched until `apply()` is called.
2. **Applies staged config on demand** — `apply()` passes the staged table to `backend:apply(staged)`. The backend is responsible for writing to the underlying config system (e.g. UCI) and restarting the daemon.
3. **Clears backend state on demand** — `clear()` calls `backend:clear()` to reset the backend's config to a known base state, ready for a fresh set of staged calls.

The driver never touches UCI or any OS config system. All writes are delegated to the active backend. A future non-OpenWrt backend can implement the same interface without any UCI involvement.

## Dependencies

- `backends/band/provider.lua` — selects the active backend at driver creation.
- DAWN must be installed on the target device. If `backend:clear()` fails on startup (e.g. DAWN config absent), the WLAN Manager logs the error and does not emit a device-added event for the band capability.

## Initialisation

On creation by the WLAN Manager:

1. Resolve the band backend via `provider.get_backend()`. If no supported backend is found, creation fails with an error.
2. Call `backend:clear()`. The backend is responsible for resetting the DAWN config to a clean base state. If `clear` fails, creation fails with an error.
3. Publish capability `meta`.
4. Start the RPC handler fiber.

## Capability

Class: `band`
Id: `'1'`

### Meta (retained)

Topic: `{'cap', 'band', '1', 'meta'}`

```lua
{
  provider = 'hal',
  version  = 1,
}
```

### Offerings

All offerings return `{ ok = true }` on success or `{ ok = false, reason = <string> }` on validation failure or internal error. Changes are staged in-memory until `apply` is called.

---

#### set_log_level

Topic: `{'cap', 'band', '1', 'rpc', 'set_log_level'}`

Stages the daemon log level.

Input:

```lua
{
  level = <number>,  -- required: non-negative integer
}
```

---

#### set_kicking

Topic: `{'cap', 'band', '1', 'rpc', 'set_kicking'}`

Stages the global client-kicking policy.

Input:

```lua
{
  mode                = <string>,  -- required: "none"|"compare"|"absolute"|"both"
  bandwidth_threshold = <number>,  -- required: non-negative
  kicking_threshold   = <number>,  -- required: non-negative
  evals_before_kick   = <number>,  -- required: non-negative integer
}
```

Mode-to-integer mapping (used by the backend): `none=0`, `compare=1`, `absolute=2`, `both=3`.

---

#### set_station_counting

Topic: `{'cap', 'band', '1', 'rpc', 'set_station_counting'}`

Stages the station-counting policy.

Input:

```lua
{
  use_station_count = <boolean>,  -- required
  max_station_diff  = <number>,   -- required: non-negative integer
}
```

---

#### set_rrm_mode

Topic: `{'cap', 'band', '1', 'rpc', 'set_rrm_mode'}`

Stages the RRM (Radio Resource Management) mode.

Input:

```lua
{
  mode = <string>,  -- required: one of "PAT"
}
```

---

#### set_neighbour_reports

Topic: `{'cap', 'band', '1', 'rpc', 'set_neighbour_reports'}`

Stages neighbour report parameters.

Input:

```lua
{
  dyn_report_num      = <number>,  -- required: non-negative integer (coerced with tonumber)
  disassoc_report_len = <number>,  -- required: non-negative integer (coerced with tonumber)
}
```

---

#### set_legacy_options

Topic: `{'cap', 'band', '1', 'rpc', 'set_legacy_options'}`

Input:

```lua
{
  opts = <table>,  -- required: key-value table; valid keys: "eval_probe_req", "eval_assoc_req", "eval_auth_req", "min_probe_count", "deny_assoc_reason", "deny_auth_reason"
}
```

Each key-value pair is staged in the driver's in-memory config table under the global section. The backend maps driver-level keys to the appropriate config system entries. Unknown keys or nil values return `ok = false`.

---

#### set_band_priority

Topic: `{'cap', 'band', '1', 'rpc', 'set_band_priority'}`

Stages the initial score (priority) for a frequency band.

Input:

```lua
{
  band     = <string>,  -- required: "2G" or "5G" (case-insensitive, normalised to upper)
  priority = <number>,  -- required: non-negative number
}
```

The backend maps `2G`/`5G` to the appropriate config section names.

---

#### set_band_kicking

Topic: `{'cap', 'band', '1', 'rpc', 'set_band_kicking'}`

Stages per-band RSSI and channel-utilisation scoring parameters.

Input:

```lua
{
  band    = <string>,   -- required: "2G" or "5G"
  options = <table>,    -- required: key-value table of scoring parameters
}
```

Valid option keys and their descriptions (all values must be numbers). The backend maps these to the appropriate config system keys:

| Option key                       | Description                                    |
|----------------------------------|------------------------------------------------|
| `rssi_center`                    | RSSI centre value                              |
| `rssi_reward_threshold`          | RSSI good threshold                            |
| `rssi_reward`                    | RSSI good reward                               |
| `rssi_penalty_threshold`         | RSSI bad threshold                             |
| `rssi_penalty`                   | RSSI bad penalty                               |
| `rssi_weight`                    | RSSI weight                                    |
| `channel_util_reward_threshold`  | Channel utilisation good threshold             |
| `channel_util_reward`            | Channel utilisation good reward                |
| `channel_util_penalty_threshold` | Channel utilisation bad threshold              |
| `channel_util_penalty`           | Channel utilisation bad penalty                |

Unknown keys return `ok = false`. Values that cannot be coerced to a number return `ok = false`.

---

#### set_support_bonus

Topic: `{'cap', 'band', '1', 'rpc', 'set_support_bonus'}`

Input:

```lua
{
  band    = <string>,   -- required: "2G" or "5G"
  support = <string>,   -- required: "ht" or "vht"
  reward  = <number>,   -- required
}
```

The backend maps driver-level keys to the appropriate config entries. Unknown keys return `ok = false`.

Topic: `{'cap', 'band', '1', 'rpc', 'set_update_freq'}`

Stages update frequencies for internal DAWN polling loops.

Input:

```lua
{
  updates = <table>,   -- required: key-value table; valid keys: "client","chan_util","hostapd","beacon_reports","tcp_con"
}
```

Values must be non-negative numbers. Unknown keys return `ok = false`.

---

#### set_client_inactive_kickoff

Topic: `{'cap', 'band', '1', 'rpc', 'set_client_inactive_kickoff'}`

Stages the inactive client kickoff timeout.

Input:

```lua
{
  timeout = <number>,  -- required: non-negative integer (coerced with tonumber)
}
```

---

#### set_cleanup

Topic: `{'cap', 'band', '1', 'rpc', 'set_cleanup'}`

Stages cleanup timeouts for probes, clients, and APs.

Input:

```lua
{
  timeouts = <table>,  -- required: key-value table; valid keys: "probe","client","ap"
}
```

Values must be non-negative numbers. Unknown keys return `ok = false`.

---

#### set_networking

Topic: `{'cap', 'band', '1', 'rpc', 'set_networking'}`

Stages the DAWN inter-AP networking method and options.

Input:

```lua
{
  method  = <string>,  -- required: "broadcast"|"tcp+umdns"|"multicast"|"tcp"
  options = <table>,   -- required: key-value table of optional networking settings
}
```

Valid option keys (the backend maps these to the appropriate config entries):

| Key                  | Type      |
|----------------------|-----------|
| `ip`                 | string    |
| `port`               | number    |
| `broadcast_port`     | number    |
| `enable_encryption`  | boolean   |

Unknown keys or type mismatches return `ok = false`.

---

#### apply

Topic: `{'cap', 'band', '1', 'rpc', 'apply'}`

Passes the full staged config table to `backend:apply(staged)`. The backend is responsible for writing to the config system and triggering a daemon restart. The backend coalesces rapid successive restarts with a 1-second debounce window.

Input: none (empty object `{}`).

---

#### clear

Topic: `{'cap', 'band', '1', 'rpc', 'clear'}`

Calls `backend:clear()` to reset the backend's DAWN config to a known base state. The in-memory staged config is also reset to empty. This should be called before beginning a new configuration sequence.

Input: none (empty object `{}`).

---

#### rollback

Topic: `{'cap', 'band', '1', 'rpc', 'rollback'}`

Discards all staged changes without any backend call. The staged config is reset to empty (same state as after `clear`).

Input: none (empty object `{}`).

---

## Types

All capability arg and reply types follow the conventions in `src/services/hal/types/`.

### `BandSetKickingOpts`

```lua
---@class BandSetKickingOpts
---@field mode string              -- "none"|"compare"|"absolute"|"both"
---@field bandwidth_threshold number
---@field kicking_threshold number
---@field evals_before_kick number
```

### `BandSetStationCountingOpts`

```lua
---@class BandSetStationCountingOpts
---@field use_station_count boolean
---@field max_station_diff number
```

### `BandSetNeighbourReportsOpts`

```lua
---@class BandSetNeighbourReportsOpts
---@field dyn_report_num number
---@field disassoc_report_len number
```

### `BandSetBandPriorityOpts`

```lua
---@class BandSetBandPriorityOpts
---@field band string    -- "2G" or "5G"
---@field priority number
```

### `BandSetBandKickingOpts`

```lua
---@class BandSetBandKickingOpts
---@field band string    -- "2G" or "5G"
---@field options table  -- see set_band_kicking valid option keys
```

### `BandSetSupportBonusOpts`

```lua
---@class BandSetSupportBonusOpts
---@field band string    -- "2G" or "5G"
---@field support string -- "ht" or "vht"
---@field reward number
```

### `BandSetNetworkingOpts`

```lua
---@class BandSetNetworkingOpts
---@field method string   -- "broadcast"|"tcp+umdns"|"multicast"|"tcp"
---@field options table
```

### `BandCapabilityReply`

```lua
---@class BandCapabilityReply
---@field ok boolean
---@field reason string|nil  -- present on failure
```

## Backend Contract

The OpenWrt-DAWN band backend (`backends/band/providers/openwrt-dawn/impl.lua`) must implement:

| Function          | Description                                                                                                    |
|-------------------|----------------------------------------------------------------------------------------------------------------|
| `is_supported()`  | Returns `true` if DAWN is installed (checks `/etc/config/dawn` exists and is readable)                        |
| `clear()`         | Deletes non-`hostapd` DAWN UCI sections; creates required fixed sections (`global`, `802_11g`, `802_11a`, `gbltime`, `gblnet`, `localcfg`) with default values; commits. Leaves the daemon in a clean state ready for fresh staged config. |
| `apply(staged)`   | Writes the staged config table to the config system and triggers `service dawn restart`. The 1-second debounce coalescing is an internal backend concern. |

Band section name mapping (`2G → 802_11g`, `5G → 802_11a`) is a detail of the backend, not the driver. The driver passes band identifiers as-is in the staged table.

The driver has no import of or dependency on `backends/common/uci.lua`.

## Service Flow

1. Resolve backend; if unsupported, stop with error.
2. Call `backend:clear()`; if it fails, stop with error.
3. Publish meta.
4. Enter `named_choice` loop on `control_ch` and scope cancellation.
5. On each RPC: validate inputs; update staged config table; reply `{ ok = true }` or `{ ok = false, reason = ... }`.
6. On `apply`: pass staged config table to `backend:apply(staged)`.
7. On `clear`: call `backend:clear()`; reset in-memory staged config.
8. On `rollback`: discard staged config table.
9. On scope cancelled: exit loop.

## Architecture

- The driver runs a single RPC handler fiber. There is no autonomous emission from the band driver.
- Staged config is a plain Lua table local to the driver. It is only ever accessed by the single RPC handler fiber (no concurrent access).
- `apply` passes the staged config table to `backend:apply(staged)`. The driver has no knowledge of how the backend writes the config.
- The clear sequence on startup is fully owned by the backend via `backend:clear()`. If it fails, the driver stops without advertising the capability.
- A `finally` block on the driver scope logs the reason for shutdown.
