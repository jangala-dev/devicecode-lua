# WiFi Service

The WiFi service provides configuration and management capabilities for wireless radios, SSIDs, and band steering on the device.

## Overview

The WiFi service manages the wireless capabilities of the device, including:
- Radio configuration (channels, bands, power)
- SSID management (creating access points)
- Band steering for optimal client connection management

## Bus Interactions

### Configuration
- **Topic**: `config.wifi`
- **Purpose**: Receives configuration updates for WiFi radios, SSIDs, and band steering.
- **Payload**: A table containing:
  - `report_period`: Frequency of status reporting in seconds.
  - `radios`: Array of radio configurations.
  - `ssids`: Array of SSID configurations.
  - `band_steering`: Band steering configuration settings.

### HAL Interactions
The WiFi service interacts extensively with the hardware abstraction layer:

#### Subscriptions
- **Topic**: `hal.capability.wireless.+`
- **Purpose**: Listens for radio device connections and disconnections.
- **Payload**: Contains connection status and device information.

- **Topic**: `hal.capability.band.+`
- **Purpose**: Monitors band steering capability initialization.
- **Payload**: Band steering service status information.

#### Publications
- **Topics**: Various HAL wireless control topics
- **Purpose**: Sends commands to configure radios, interfaces, and band steering.
- **Examples**:
  - `hal.capability.wireless.<index>.control.clear_radio_config`
  - `hal.capability.wireless.<index>.control.set_channels`
  - `hal.capability.wireless.<index>.control.add_interface`
  - `hal.capability.band.1.control.set_kicking`

## Metrics

The WiFi service publishes metrics about wireless interfaces and connected clients to the bus. These metrics are collected from the HAL wireless driver and published for consumption by the metrics service.

### HAL Wireless Driver Output

The HAL wireless driver publishes information on the following topics:

- **`hal.capability.wireless.<radio>.info.interface.<interface>.client.<mac>`** - Client connection/disconnection events with timestamp
- **`hal.capability.wireless.<radio>.info.interface.<interface>.client.<mac>.<metric>`** - Individual client metrics (tx_bytes, rx_bytes, signal, noise, hostname, etc.)
- **`hal.capability.wireless.<radio>.info.interface.<interface>.<metric>`** - Interface-level metrics (channel, power, noise, traffic counters)

### Published Metrics

#### Interface Metrics
Published on topic: `wifi/hp/<hardware_platform>/rd<radio_band>/<interface_index>/<metric>`

Available interface metrics:
- `num_sta` - Number of connected stations
- `channel` - Current operating channel
- `power` - Transmit power (dBm)
- `noise` - Noise level (dBm)
- `rx_bytes` - Received bytes
- `rx_packets` - Received packets
- `rx_dropped` - Dropped received packets
- `rx_errors` - Receive errors
- `tx_bytes` - Transmitted bytes
- `tx_packets` - Transmitted packets
- `tx_dropped` - Dropped transmitted packets
- `tx_errors` - Transmit errors

#### Client Session Metrics
Published on topic: `wifi/clients/<client_hash>/sessions/<session_id>/<metric>`

Available client metrics:
- `session_start` - Timestamp when client connected
- `session_end` - Timestamp when client disconnected
- `hostname` - Client hostname (from DHCP lease)
- `rx_bytes` - Bytes received from client
- `tx_bytes` - Bytes transmitted to client
- `signal` - Client signal strength (dBm)

**Note**: Client noise is not reported separately as it duplicates the interface-level noise metric.

Client sessions are identified by a hash of the client's MAC address and a unique session ID generated when the client connects.

## Configuration

The WiFi service accepts a configuration message on the `config.wifi` topic with the following structure:

```lua
{
  report_period = <number>,     -- Reporting period in seconds
  radios = {                    -- List of radio configurations
    {
      name = <string>,          -- Radio identifier
      band = <string>,          -- Radio band (2g, 5g, 6g)
      channel = <number>,       -- Primary channel
      htmode = <string>,        -- Channel width (HT20, HT40, VHT80, etc.)
      channels = <table>,       -- Additional channel configuration
      txpower = <number>,       -- Transmit power in dBm
      country = <string>,       -- Country code
      disabled = <boolean>      -- Whether the radio is disabled
    },
    -- Additional radios...
  },
  ssids = {                     -- List of SSID configurations
    {
      name = <string>,          -- SSID name
      radios = {<string>, ...}, -- List of radio names to apply this SSID to
      mode = <string>,          -- Interface mode (access_point, client, etc.)
      network = <string>,       -- Network interface to bridge with
      encryption = <string>,    -- Encryption type (none, psk2, etc.)
      password = <string>       -- Passphrase for encrypted networks
    },
    -- Additional SSIDs...
  },
  band_steering = {             -- Band steering configuration
    globals = {
      kick_mode = <string>,           -- Mode for steering clients (none, compare, absolute, both)
      bandwidth_threshold = <number>, -- Bandwidth usage threshold for steering
      kicking_threshold = <number>,   -- Threshold for client steering
      evals_before_kick = <number>    -- Evaluations before steering action
    },
    timings = {
      update_client = <number>,         -- Client update interval in seconds
      update_chan_util = <number>,      -- Channel utilization update interval
      update_hostapd = <number>,        -- HostAPD update interval
      client_cleanup = <number>,        -- Client cleanup interval
      inactive_client_kickoff = <number>-- Inactive client removal interval
    },
    bands = {
      ["2g"] = {                        -- Configuration for 2.4GHz band
        initial_score = <number>,       -- Initial band preference score
        good_rssi_threshold = <number>, -- Threshold for good signal strength
        good_rssi_reward = <number>,    -- Score increase for good signal
        bad_rssi_threshold = <number>,  -- Threshold for poor signal strength
        bad_rssi_penalty = <number>,    -- Score decrease for poor signal
        rssi_center = <number>,         -- Center RSSI value
        weight = <number>               -- Band weight for scoring
      },
      ["5g"] = {
        -- Similar configuration for 5GHz band
      },
      -- Additional bands...
    }
  }
}
```

## Interface Modes

The following interface modes are supported:

- `access_point` - Acts as an access point for clients to connect
- `client` - Connects to another access point
- `adhoc` - Ad-hoc network mode
- `mesh` - Mesh networking mode
- `monitor` - Network monitoring mode

## Implementation

The WiFi service consists of several components:

1. **Radio Class** - Manages individual radio hardware
2. **Radio Listener** - Detects radio hardware connections/disconnections
3. **Radio Manager** - Applies configurations and manages the lifecycle of radios

The service integrates with the HAL wireless capability to control the underlying wireless hardware.

## Examples

### Basic configuration with one radio and SSID

```lua
{
  report_period = 10,
  radios = {
    {
      name = "radio0",
      band = "2g",
      channel = 6,
      htmode = "HT20",
      txpower = 20,
      country = "US"
    }
  },
  ssids = {
    {
      name = "MyNetwork",
      radios = {"radio0"},
      mode = "access_point",
      network = "lan",
      encryption = "psk2",
      password = "securepassword"
    }
  },
  band_steering = {
    globals = {
      kick_mode = "both",
      bandwidth_threshold = 70,
      kicking_threshold = -60,
      evals_before_kick = 3
    },
    timings = {
      update_client = 10,
      update_chan_util = 30,
      update_hostapd = 15,
      client_cleanup = 300,
      inactive_client_kickoff = 600
    },
    bands = {
      ["2g"] = {
        initial_score = 50,
        good_rssi_threshold = -55,
        good_rssi_reward = 10,
        bad_rssi_threshold = -75,
        bad_rssi_penalty = 10,
        rssi_center = -65,
        weight = 1
      }
    }
  }
}
```

### Advanced configuration with multiple radios and SSIDs

```lua
{
  report_period = 10,
  radios = {
    {
      name = "radio0",
      band = "2g",
      channel = 6,
      htmode = "HT20",
      txpower = 20,
      country = "US"
    },
    {
      name = "radio1",
      band = "5g",
      channel = 36,
      htmode = "VHT80",
      txpower = 23,
      country = "US"
    }
  },
  ssids = {
    {
      name = "MyNetwork",
      radios = {"radio0", "radio1"},
      mode = "access_point",
      network = "lan",
      encryption = "psk2",
      password = "securepassword"
    },
    {
      name = "GuestNetwork",
      radios = {"radio0"},
      mode = "access_point",
      network = "guest",
      encryption = "none"
    }
  },
  band_steering = {
    -- configuration as in the basic example
  }
}
```
