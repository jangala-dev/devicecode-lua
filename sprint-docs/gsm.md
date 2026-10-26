# GSM Service Documentation

## Overview

The GSM service is responsible for managing GSM modems, handling their configuration, and ensuring they connect to the network using appropriate APNs. This document provides a high-level overview (black box) and a detailed internal explanation of how the `gsm.lua` module works.

## GSM Interface Overview

### Responsibilities

- **Modem Management**: Detects and manages GSM modems.
- **Configuration Handling**: Applies configurations to modems based on their IMEI or device type.
- **Network Connection**: Attempts to connect modems to the network using ranked APNs.
- **State Monitoring**: Monitors the state of modems and handles state transitions.

### Key Functions

- **`gsm_service:start`**: Starts the GSM service and initializes the modem manager.

### Bus Interactions

- **Incoming Messages**:
  - **Modem Capability**: Subscribes to `hal/capability/modem/+` to handle modem capability messages.
  - **Modem Info**: Subscribes to various endpoints under `hal/capability/modem/<modem_index>/info/` to get state and hardware information
  - **Configuration**: Subscribes to `config/gsm` to handle configuration messages.

- **Outgoing Messages**:
  - **Modem Control**: Publishes commands to various endpoints under `hal/capability/modem/<modem_index>/control/` to navigate modem through the state machine.
  - **Network Interface**: Publishes network interface information to `gsm/modem/<modem_idx>/net-interface`.

### Configuration

- **Default Configuration**: Holds default settings for modems.
- **Known Modems**: Specific configurations for known modems identified by IMEI or device path.

### Cellular generations

Within the existing `devicecode.config/gsm/1` schema, modem defaults and individual
`modems.known` entries may specify:

```json
"cellular_modes": {
  "preferred": "4g",
  "allowed": ["3g", "4g"]
}
```

Generations are `2g`, `3g`, `4g`, and `5g`. Preferred may also be `none` to request
no explicit preference. Both fields must be present after inheritance from modem
defaults. Missing fields inherit individually; an explicit allowed list replaces
the default list completely. Allowed lists must be nonempty; duplicates and order
have no significance.

GSM applies settings only when the modem advertises an exact preferred/allowed
pair. If no pair matches, GSM logs a warning and leaves the modem's current modes
unchanged. It does not add or remove allowed generations or substitute a different
preference, including `none` for a single-generation request.

Settings apply on modem discovery, configuration changes, and recovery, including
when `autoconnect` is false. Initialization, locked SIMs, and failed modem states
defer application until the modem becomes usable. Changes apply to connected
modems and may briefly interrupt connectivity. GSM skips an already-matching
setting, verifies writes by reading the modes back, and retries I/O/apply failures
after 20 seconds independently of APN retries. Invalid or unsupported requests
produce per-modem warnings without blocking normal connection management.

Omitting `cellular_modes` preserves existing behavior. Removing the effective
settings stops managing modes; it does not reset the modem to automatic selection.
Unsupported requests and application failures log the requested pair and reason.

HAL exposes `get` fields `supported_modes` (a list of combinations) and
`current_modes` (one combination), each shaped as `{preferred, allowed}`. The
`set_modes` control operation takes typed `ModemSetModesOpts(preferred, allowed)`.
The modem backend provides `read_modes()` and `set_modes(preferred, allowed)`;
generation configuration validation belongs to GSM.

## GSM Internal Overview

### Data Structures

- **`configs`**: Holds configurations for modems, indexed by IMEI or device type.
- **`modems`**: Stores active modems, indexed by preferred ID fields (IMEI or device).

### Classes and Methods

#### `Modem` Class

- **`Modem:autoconnect(ctx, cutoff)`**:
  - Gathers Modem and sim information.
  - Retrieves ranked APNs and attempts to connect using them.
  - Monitors the connection status and retries if necessary.

- **`Modem:enable_autoconnect(ctx)`**:
  - Spawns a fiber to monitor modem state changes.
  - Handles state transitions such as `failed`, `no_sim`, `disabled`, `registered`, and `connected`.

- **`Modem:update_config(config)`**:
  - Updates the modem configuration and enables/disables autoconnect based on the configuration.

- **`new_modem(ctx, bus_conn, imei, index, modemcard)`**:
  - Creates a new modem instance and initializes its context, bus connection, IMEI, index, and modem card.

#### `gsm_service` Table

- **`gsm_service:start(service_ctx, bus_connection)`**:
  - Starts the GSM service by spawning a fiber for the GSM manager.
  - The GSM manager handles modem capability detection and configuration updates.

### Event Handling

- **`modem_capability_handler(ctx, bus_conn, modem_capability_msg)`**:
  - Handles modem capability messages, subscribes to modem information topics, and updates the modem configuration.

- **`config_handler(config_msg)`**:
  - Handles configuration messages, updates the default and known modem configurations, and applies them to active modems.

### GSM Manager

- **`gsm_manager(ctx, bus_conn)`**:
  - Subscribes to modem capability and configuration topics.
  - Processes capability and configuration messages in a loop, updating modem states and configurations as needed.

### Modem State Transitions

```mermaid
stateDiagram
    [*] --> Disabled
    [*] --> Failed
    Disabled --> Enabled : enable
    NoSim --> Disabled : sim_inserted
    Registered --> NoSim
    Connected --> NoSim
    Enabled --> Registered : sim_detect
    Registered --> Connecting : autoconnect
    Connecting --> Connected : success
    Failed --> Disabled : fix_failure
```
