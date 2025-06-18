# System Service Documentation

The System Service is responsible for managing system-level operations, including USB hub control, system information reporting, and alarm handling. It interacts with the message bus to receive configurations and publish system metrics.

---

## Outward-Facing API

### 1. **Bus Events**
The System Service interacts with the message bus to receive configuration updates and publish system information.

#### **Configuration**
- **Topic**: `config/system`
- **Purpose**: Receives configuration updates for the system service.
- **Payload**: A table containing:
  - `usb3_enabled`: Boolean to enable or disable USB 3.0.
  - `report_period`: Interval (in seconds) for publishing system information.
  - `alarms`: A list of alarm configurations.

#### **System Information and Metrics**
All endpoints start with `system/info` and provide detailed system information and metrics:

- **`device/model`**: Publishes hardware model.
- **`device/version`**: Publishes hardware version.
- **`firmware/version`**: Publishes firmware version.
- **`boot_time`**: Publishes system boot time.
- **`cpu/overall_utilisation`**: Publishes overall CPU utilization.
- **`cpu/core_utilisations`**: Publishes per-core CPU utilization.
- **`cpu/average_frequency`**: Publishes average CPU frequency.
- **`cpu/core_frequencies`**: Publishes per-core CPU frequencies.
- **`memory/total`**: Publishes total memory.
- **`memory/used`**: Publishes used memory.
- **`memory/free`**: Publishes free memory.
- **`temperature`**: Publishes system temperature.

#### **Alarms**
- **Topic**: `+/control/shutdown`
- **Purpose**: Publishes shutdown or reboot commands triggered by alarms.
- **Payload**: A table containing:
  - `reason`: The reason for the shutdown or reboot.
  - `deadline`: The deadline for completing the operation.

---

### 2. **`start` Function**
Initializes and starts the System Service.

#### **Signature**
```lua
system_service:start(ctx, bus_connection)
```

#### **Parameters**
- `ctx`: The execution context for the service.
- `bus_connection`: The connection to the message bus.

#### **Behavior**
- Spawns fibers for:
  - The main system loop.
  - System information reporting.

---

## Internal API

### 1. **Configuration Handling**
#### **`_handle_config(config_msg)`**
Processes configuration messages and applies updates to the system.

- **Parameters**:
  - `config_msg`: A message containing the system configuration.
- **Behavior**:
  - Updates the USB 3.0 state based on the `usb3_enabled` field.
  - Updates the reporting period for system metrics.
  - Configures alarms based on the `alarms` field.

---

### 2. **System Information Reporting**
#### **`_report_sysinfo()`**
Publishes system metrics at regular intervals.

- **Behavior**:
  - Retrieves CPU utilization, memory usage, and temperature using the `sysinfo` module.
  - Publishes the metrics to the message bus.
  - Adjusts the reporting interval dynamically based on configuration updates.

---

### 3. **Alarm Handling**
#### **`_handle_alarm(alarm)`**
Handles alarms and triggers appropriate actions.

- **Parameters**:
  - `alarm`: An alarm object containing the name, type, and action to perform.
- **Behavior**:
  - Publishes a shutdown or reboot command to the message bus.
  - Monitors the shutdown process and logs any issues with hanging services.

---

### 4. **USB 3.0 Management**
#### **`disable_usb3()`**
Disables USB 3.0 functionality on supported hardware.

- **Behavior**:
  - Checks the firmware version of the USB hub controller.
  - Deauthorizes and powers down USB 3.0 ports.
  - Monitors the transition of devices to USB 2.0.

---

### 5. **Main Loop**
#### **`_system_main()`**
The main loop of the System Service.

- **Behavior**:
  - Subscribes to configuration and health topics.
  - Processes configuration updates and alarm events.
  - Tracks the state of other services and ensures graceful shutdowns.

---

## Supporting Modules

### **`usb3.lua`**
Manages USB 3.0 hub operations, including port authorization and power control.

- **Key Functions**:
  - `set_usb_hub_auth_default(ctx, enabled, hub)`: Enables or disables default authorization for a USB hub.
  - `clear_usb_3_0_hub(ctx)`: Deauthorizes all USB 3.0 ports.
  - `set_usb_hub_power(ctx, enabled, hub)`: Powers the USB hub on or off.

---

### **`sysinfo.lua`**
Retrieves system information, such as CPU utilization, memory usage, and temperature.

- **Key Functions**:
  - `get_cpu_utilisation_and_freq(ctx)`: Retrieves CPU utilization and frequency.
  - `get_ram_info()`: Retrieves total, used, and free memory.
  - `get_temperature()`: Retrieves the system temperature.
  - `get_uptime()`: Retrieves the system uptime.

---

## Configuration Example

```json
{
  "system": {
    "report_period": 1,
    "usb3_enabled": false,
    "alarms": [
      {
        "name": "daily reboot",
        "action": "reboot",
        "datetime": "8:48",
        "repeats": "daily"
      }
    ]
  }
}
```

- **`report_period`**: Sets the interval for publishing system metrics.
- **`usb3_enabled`**: Disables USB 3.0 functionality.
- **`alarms`**: Configures a daily reboot alarm.

---

## Workflow

1. **Initialization**:
   - Subscribes to configuration and health topics.
   - Initializes alarm management and system metrics reporting.

2. **Configuration Updates**:
   - Processes configuration messages to update USB 3.0 state, reporting intervals, and alarms.

3. **Metrics Reporting**:
   - Publishes system metrics at regular intervals.

4. **Alarm Handling**:
   - Triggers shutdown or reboot actions based on alarm events.

---

## Error Handling

- Logs errors for invalid configurations, USB hub operations, and system metrics retrieval.
- Uses `pcall` to safely execute critical operations.
