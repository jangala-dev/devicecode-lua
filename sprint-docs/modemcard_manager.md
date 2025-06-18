# Modem Card Manager Documentation

## Table of Contents
1. [Overview](#overview)
2. [Features](#features)
3. [Architecture](#architecture)
6. [API Reference](#api-reference)
   - [Initialization](#initialization)
   - [Modem Detection](#modem-detection)
   - [Modem Manager](#modem-manager)
7. [Usage Examples](#usage-examples)
8. [Testing](#testing)
9. [Known Limitations](#known-limitations)

---

## Overview
### Key Objectives
- Monitor and manage connected modems dynamically.
- Send modem events to HAL for integration with other services.
- Allow for configuration of modems.

---

## Features
- **Dynamic Modem Detection**: Detects when modems are connected or disconnected.
- **Events**: Sends modem events (e.g., detection, removal) to HAL with device and capability control interfaces.
- **Configuration Management**: Applies configurations to modems.
- **Asynchronous Design**: Uses `fibers` for non-blocking, concurrent operations.

---

## Architecture
### Core Components
1. **Modem Manager**:
   - Handles the lifecycle of modems (detection, configuration, removal).

2. **Modem Detector**:
   -  Monitors modem state through `mmcli`
   -  Sends modem card events to the manager for handling

2. **Communication**:
   - **Detection Channel**: Connection between detector and manager to signal a detection event.
   - **Removal Channel**: Connection between detector and manager to signal a removale event.
   - **Configuration Channel**: Modem configs sent from top-level HAL.
   - **Device Event Queue**: output to top-level HAL to signal modemcard connected/disconnected.

3. **Message Bus**:
   - This is used to send the modem driver state monitor and command fibers' data

4. **Test Shims**:
   - Mocked dependencies for testing modules which typically interact with hardware components (e.g., `mmcli` shim).

---

## API Reference

### Initialisation
```lua
local modem_manager = require("services.hal.modemcard_manager")
local instance = modem_manager.new()
```
- **Description**: Initialises a new instance of the modem card manager.
- **Parameters**: None.
- **Returns**: A new `ModemManagement` instance.

---

### Modem Detection
```lua
instance:detector(context, detect_channel, remove_channel)
```
- **Description**: Starts monitoring for modem detection and removal.
- **Parameters**:
  - `context`: The parent context for managing the detector's lifecycle.
  - `detect_channel`: Channel for notifying detected modems.
  - `remove_channel`: Channel for notifying removed modems.
- **Returns**: None.

---

### Modem Manager
```lua
instance:manager(context, bus_connection, device_event_q, config_channel, detect_channel, remove_channel)
```
- **Description**: Manages modem configuration and state transitions.
- **Parameters**:
  - `context`: The parent context for managing the manager's lifecycle.
  - `bus_connection`: Connection to the message bus for publishing events.
  - `device_event_q`: Queue for device events.
  - `config_channel`: Channel for receiving configuration changes.
  - `detect_channel`: Channel for notifying detected modems.
  - `remove_channel`: Channel for notifying removed modems.
- **Returns**: None.

---

## Testing
1. Run the test suite:
   ```bash
   make test
   ```
2. Verify output:
   - Some error messages may be logged but the script will not crash, ignore these messages
   - All tests should pass with a "Tests completed" message.

---

## Known Limitations/Futures
- Requires `mmcli` for full functionality; limited without it.
- Device control is not yet fully implemented (will be built out as other services are made)
- Full modem configs may be changed as GSM develops
