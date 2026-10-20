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

Set `pdp_type` in `modems.default` or override it in a `modems.known` entry.
Accepted values are `IP`, `IPV4V6`, and `IPV6`. Modems inherit the default;
if neither specifies a type, GSM uses `IP`.

```json
{
  "schema": "devicecode.config/gsm/1",
  "modems": {
    "default": { "enabled": true, "pdp_type": "IP" },
    "known": [
      { "name": "primary", "imei": "123456789012345", "pdp_type": "IPV4V6" }
    ]
  }
}
```

Whenever the modem is disabled, GSM checks active PDP contexts against its
configured `pdp_type` before enabling it. Mismatched contexts are corrected and
verified, then the modem is restarted once. On the next disabled-state pass,
matching contexts need no writes or restart and autoconnect can enable the modem.
Read, write, or restart failures are retried before enabling.
If no contexts are reported active, no contexts are rewritten.

PDP commands are allowed in disabled or registered state; restart is allowed from
any state. Unsupported manufacturers retain their existing enable/connect behavior.
The backend prefers the secondary AT port and falls back to the primary AT port
when no secondary port is available.
Changing this setting does not immediately disconnect an already connected modem;
it is enforced the next time the modem is disabled.

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
