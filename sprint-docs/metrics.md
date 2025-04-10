# Metrics Service Documentation

The Metrics Service is responsible for collecting, processing, and publishing metrics data in a structured and configurable manner. It is implemented in the `metrics.lua` file and relies on several supporting modules in the `metrics` folder.

---

## Outward-Facing API

### 1. **Bus Events**
The Metrics Service interacts with the message bus to receive configuration updates and metrics data.

#### **Configuration**
- **Topic**: `config/metrics`
- **Purpose**: Receives configuration updates for the metrics service.
- **Payload**: A table containing:
  - `publish_cache`: Cache configuration (flush period).
  - `collections`: Definitions of metrics endpoints, processing pipelines, and publishing protocols.

#### **Metrics**
- **Any Subscriptions**: The service subscribes to any bus endpoint defined in the configuration.
- **Payload**: Metrics data, which may include specific fields as defined in the configuration.

---

### 2. **`start` Function**
Initializes and starts the Metrics Service.

#### **Signature**
```lua
metrics_service:start(ctx, bus_connection)
```

#### **Parameters**
- `ctx`: The execution context for the service.
- `bus_connection`: The connection to the message bus.

#### **Behavior**
- Spawns a fiber to handle configuration updates, metrics processing, and cache flushing.

---

## Internal API

### 1. **Configuration Handling**
#### **`_handle_config(config)`**
Parses and applies the metrics configuration.

- **Parameters**:
  - `config`: A table containing the metrics configuration.
- **Behavior**:
  - Validates the configuration.
  - Sets up the publish cache and processing pipelines for each bus endpoint.
  - Handles overriding endpoints for more specific pipelines.

---

### 2. **Processing Pipelines**
#### **`_build_metric_pipeline(endpoint, process_config)`**
Constructs a processing pipeline for a given endpoint.

- **Parameters**:
  - `endpoint`: A bus endpoint.
  - `process_config`: The configuration for the processing pipeline.
- **Returns**:
  - A `ProcessPipeline` instance or an error message.

---

### 3. **Publishing**
#### **`_publish_all(data)`**
Publishes all metrics data using the configured protocols.

- **Parameters**:
  - `data`: A table containing metrics data grouped by protocol.
- **Behavior**:
  - Iterates over the data and invokes the appropriate publishing function for each protocol.
  - Logs errors for unsupported protocols or publishing failures.

#### **`_log_publish(val)`**
Logs metrics data for testing purposes.

- **Parameters**:
  - `val`: The metrics data to log.
- **Behavior**:
  - Recursively prints the metrics data to the console.

---

### 4. **Main Loop**
#### **`_main()`**
The main loop of the Metrics Service.

- **Behavior**:
  - Subscribes to the configuration topic and initializes the cache.
  - Handles configuration updates, metrics processing, and cache flushing in a loop.
  - Terminates gracefully when the context is canceled.

---

### 5. **Utility Functions**
#### **`valid_override_endpoint(endpoint, override_endpoint)`**
Checks if an overriding endpoint matches the original endpoint such that only wildcards are changed.

- **Parameters**:
  - `endpoint`: The original endpoint.
  - `override_endpoint`: The overriding endpoint.
- **Returns**:
  - `true` if the override is valid, `false` otherwise.

---

## Supporting Modules

### **`timed_cache.lua`**
Manages a timed cache for aggregating and flushing metrics data.

- **Key Methods**:
  - `TimedCache.new(period, time_method)`: Creates a new timed cache.
  - `TimedCache:set(key, value)`: Sets a value in the cache.
  - `TimedCache:get_op()`: Returns an operation that flushes the cache and resets it.

---

### **`processing.lua`**
Defines processing blocks and pipelines for transforming metrics data.

- **Processing Blocks**:
  - `Process`: Base class for processing blocks.
  - `DiffTrigger`: Emits a value when a threshold is exceeded.
  - `TimeTrigger`: Emits a value at regular intervals.
  - `DeltaValue`: Calculates the difference between the current and last published value.
  - `ProcessPipeline`: Chains multiple processing blocks into a pipeline.

#### **How Processing Blocks Work**
Processing blocks are the building blocks of a processing pipeline. They manage their internal state to either transform an input value into a output value or short circuit.

- **`run(value)`**:
  - Called every time a value is passed to the processing block.
  - Processes the input value and determines whether the pipeline should continue or short-circuit.
  - Returns the processed value, a short-circuit flag, and an optional error message.

- **`clone()`**:
  - Creates a copy of the processing block or pipeline.
  - Used to create independent instances of the same configuration.

- **`reset()`**:
  - Called when the timed cache flushes its data.
  - Resets the internal state of the processing block.
  - Only called if the processing pipeline it resides in output a value before the cache flushed.

---

#### **Configuration Options for Processing Blocks**

1. **`DiffTrigger`**
   - **Purpose**: Emits a value when the difference between the current and last output value exceeds a threshold.
   - **Config Options**:
     - `type`: `"DiffTrigger"` (required).
     - `diff_method`: `"absolute"`, `"percent"`, or `"any-change"` (required).
     - `threshold`: A number specifying the threshold for triggering (required).

   **Example**:
   ```json
   {
     "type": "DiffTrigger",
     "diff_method": "percent",
     "threshold": 10
   }
   ```

2. **`TimeTrigger`**
   - **Purpose**: Emits a value at regular time intervals.
   - **Config Options**:
     - `type`: `"TimeTrigger"` (required).
     - `duration`: A number specifying the interval in seconds (required).

   **Example**:
   ```json
   {
     "type": "TimeTrigger",
     "duration": 5
   }
   ```

3. **`DeltaValue`**
   - **Purpose**: Calculates the difference between the current and last value.
   - **Config Options**:
     - `type`: `"DeltaValue"` (required).
     - `initial_val`: A number specifying the initial value (optional, defaults to `0`).

   **Example**:
   ```json
   {
     "type": "DeltaValue",
     "initial_val": 0
   }
   ```

4. **`ProcessPipeline`**
   - **Purpose**: Chains multiple processing blocks into a pipeline.
   - **Config Options**:
     - A list of processing blocks, each with its own configuration.

   **Example**:
   ```json
   [
     {
       "type": "DiffTrigger",
       "diff_method": "absolute",
       "threshold": 5
     },
     {
       "type": "DeltaValue",
       "initial_val": 0
     }
   ]
   ```

---

## Configuration Example

```json
{
  "metrics": {
    "publish_cache": {
      "period": 60
    },
    "default_process": [
      {
        "type": "DiffTrigger",
        "threshold": 10,
        "diff_method": "absolute"
      },
      {
        "type": "DeltaValue",
        "initial_val": 0
      }
    ],
    "collections": {
      "system/cpu/usage": {
        "protocol": "log",
        "process": [
          {
            "type": "DiffTrigger",
            "threshold": 5,
            "diff_method": "percent"
          },
          {
            "type": "DeltaValue",
            "initial_val": 0
          }
        ]
      },
      "system/memory/usage": {
        "protocol": "log",
        "process": []
      }
    }
  }
}
```

- **`publish_cache`**: Creates a timed cache with a publishing period of every 60 seconds
- **`system/cpu/usage`**: Uses a processing pipeline with `DiffTrigger` followed by `DeltaValue`.
- **`system/memory/usage`**: No processing is applied; raw metrics data is logged directly.

---

## Workflow

1. **Initialization**:
   - Subscribes to the config service and initializes the cache and processing pipelines based on initial config message.

2. **Processing Metrics**:
   - Receives metrics data from the bus and processes it using the appropriate pipeline.

3. **Publishing**:
   - Flushes the publish cache at regular intervals and publishes metrics data.

---

## Extensibility

- **Custom Processing Blocks**: Add new `Process` classes for additional transformations.
- **New Protocols**: Implement `_protocol_publish` methods for additional publishing protocols.

---

## Error Handling

- Logs errors for invalid configurations, processing failures, and publishing issues.
- Uses `pcall` to safely execute protocol-specific publishing functions.

---

## Future Improvements

- Add support for more publishing protocols (e.g., HTTP, MQTT).
- Enhance configuration validation and error reporting.

