# HAL (Hardware Abstraction Layer) Service Documentation

## Overview
The HAL (Hardware Abstraction Layer) service is responsible for managing hardware devices and their capabilities in a modular and extensible way. It handles device connections, disconnections, and provides an interface for interacting with device capabilities (e.g., modem, geo, time).

---

## Key Components

### 1. **Capabilities**
Capabilities represent the functionalities provided by devices. The HAL service currently supports the following capabilities:
- **Modem**: Manages modem-related operations (e.g., enable, disable, connect).
- **Geo**: Manages geolocation-related operations (not fully implemented).
- **Time**: Manages time-related operations (not fully implemented).

Capabilities are tracked using a `tracker` object, which assigns an incrementing id with each capability created, for example adding two modem capabilities would create modem/1 and modem/2.

### 2. **Devices**
Devices are tracked by both their **index** (for bus-side access) and **ID** (for hardware manager-side access). Device ID is specific to device type, currently USB devices use their port as ID. The HAL service currently supports USB devices, but the architecture allows for extending to other device types.

### 3. **Configuration Receiver**
The `config_receiver` function listens for configuration updates on the bus and applies them to the HAL service. It currently handles modem card configurations but is designed to be extensible for other configuration types.

### 4. **Control Loop**
The `control_main` function is the main control loop of the HAL service. It handles:
- **Device Events**: Connection and disconnection of devices.
- **Capability Requests**: Requests to interact with device capabilities.
- **Device Info Requests**: Requests for device-specific information.

---

## API Reference

### **`hal_service:start(bus_connection, ctx)`**
Starts the HAL service by spawning fibers for configuration reception, control loop, and modem card management.

- **Parameters**:
  - `bus_connection`: The connection to the message bus.
  - `ctx`: The context for managing the lifecycle of the service.
- **Behavior**:
  - Spawns fibers for:
    - Configuration reception (`config_receiver`).
    - Main control loop (`control_main`).
    - Modem card manager and detector.

---

## Device Event Structure
Device events describe the connection or disconnection of a device. They have the following structure:

```lua
{
    connected = true, -- Boolean indicating if the device is connected or disconnected
    type = 'usb',     -- Device type (e.g., 'usb')
    identifier = 'device_id', -- Unique identifier for the device
    identity = {
        device = 'modemcard', -- Device type (e.g., 'modemcard')
        name = 'unknown',     -- Device name
        imei = '123456789',   -- Device IMEI
        port = 'port_name'    -- Device port
    },
    capabilities = {
        modem = modem_capability_instance, -- Modem capability instance
        geo = geo_capability_instance,     -- Geo capability instance (if applicable)
        time = time_capability_instance    -- Time capability instance (if applicable)
    },
    device_control = {
        -- Device-specific control methods (e.g., utilisation)
    }
}
```

---

## Capability Control Topic Format
Capability requests are made using the following topic format:
```
hal/<cap_name>/<index>/control/<endpoint_name>
```
- `cap_name`: The name of the capability (e.g. `modem`).
- `index`: The index of the capability instance.
- `endpoint_name`: The name of the endpoint (e.g., `enable`, `disable`).

Example:
```
hal/modem/1/control/enable
```

---

## Device Info Topic Format
Device info requests are made using the following topic format:
```
hal/device/<device_name>/<index>/info/<endpoint_name>
```
- `device_name`: The name of the device type (e.g., `usb`).
- `index`: The index of the device instance.
- `endpoint_name`: The name of the info endpoint (e.g., `utilisation`).

Example:
```
hal/device/usb/1/info/state
```

---

## Error Handling
The HAL service logs errors using the `log.error` function. Common errors include:

- **Invalid Capability**: Requested capability does not exist.

- **Invalid Device**: Requested device does not exist.

- **Invalid Endpoint**: Requested endpoint does not exist.

---

## Example Usage
### Starting the HAL Service

```lua
local hal_service = require "services.hal"
local bus = require "bus"
local context = require "fibers.context"

local bus_inst = bus.new({ q_len = 10, m_wild = '#', s_wild = '+', sep = "/" })
local bus_connection = bus_inst:connect()
local ctx = context.background()

hal_service:start(bus_connection, ctx)
```

### Requesting a Capability
```lua
local bus_connection = bus_inst:connect()
local sub = bus_conn:request({
    topic = "hal/modem/1/control/enable",
    payload = {} -- args would go here
})

local response = sub:next_msg()
```

---

## Notes

- The HAL service is designed to be extensible. New capabilities and device types can be added by extending the capabilities and devices tables.
- The service is currently focused on USB devices and modem capabilities but can be adapted for other hardware types.
