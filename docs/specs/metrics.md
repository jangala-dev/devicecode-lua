# Metrics Service

## Description

The metrics service listens to the bus for metrics, applies processing to these metrics and publishes the result to the cloud.

## Config

The metrics service takes a selection of configs, validates them and then applies all parts of the config that are valid. If globally required parts of the config are not valid then the whole service fails (publish_period, all pipelines fail). Any pipeline that uses a failed template also fails. A missing cloud URL means any HTTP protocol metrics also fail and the HTTP publisher cannot be started.

`publish_period`: The period for which metrics are cached before publishing to the cloud, recorded in seconds

`cloud_url`: The url used to publish http metrics to

`templates`: a k-v set of metric pipelines that can be reused in the pipelines section, good for different metrics that use the same pipeline without repetition

`pipelines`: a k-v set of metric pipelines (`name` to pipeline)
- `name`: The name of the metric e.g. `rx_bytes`

A pipeline is defined as:

- `template`: An optional argument for using a template (can be modified with further arguments)
- `protocol`: The protocol to be used for publication, either log or http
- `process`: A list of processing blocks to be used on the metric
- - `type`: The process block name
- - additional fields are the arguments for that block (flat, not nested under an `args` key)

An example config

```json
"metrics": {
  "publish_period": 60,
  "cloud_url": "cloud.com",
  "templates": {
    "network_stat": {
      "protocol": "http",
      "process": [
        {
          "type": "DiffTrigger",
          "diff_method": "percent",
          "threshold": 5,
          "initial_val": 0
        },
        {
          "type": "DeltaValue"
        }
      ]
    }
  },
  "pipelines": {
    "rx_bytes": {
      "template": "network_stat"
    },
    "sim": {
      "protocol": "log",
      "process": [
        {
          "type": "DiffTrigger",
          "diff_method": "any-change"
        }
      ]
    }
  }
}
```

## Metrics over the Bus

Metrics received over the bus will need to be in a specific format to be processed. The metric payload must include a `value` field and may also contain a `namespace` field. The namespace is a list of string or integer tokens which denotes the full senml key of that metric. Without a namespace, the metric key will be derived from the bus topic path.

The bus topic path determines which pipeline config is applied to the metric. The topic is an array of strings/integers that form the metric's endpoint identifier. The exact topic structure depends on the bus namespace conventions used (see runtime model documentation for topic organization).

An example bus message for a simple metric:

```lua
{
  topic = { <prefix_tokens>, <metric_name> },  -- e.g., { 'obs', 'v1', 'network', 'metric', 'rx_bytes' }
  payload = {
    value = 50
  }
}
```

Or a metric with a namespace override:

```lua
{
  topic = { <prefix_tokens>, <metric_name> },  -- e.g., { 'obs', 'v1', 'modem', 'metric', 'sim' }
  payload = {
    value = 'present',
    namespace = { 'modem', 1 }  -- overrides the senml key structure
  }
}
```

To make creation and validation of a metric easier the service will provide an sdk which will include a types module; with the types module the user can create a metric type which will validate the arguments provided and return a metric type or error. The service can accept metrics types or tables which it will validate by trying to cast to a metric type.

## Configuration & Validation

The metrics service validates all configuration on receipt and handles invalid configs gracefully:

### Validation Rules

- `publish_period`: Must be a positive number (seconds). Invalid values cause service to reject entire config.
- `cloud_url`: Must be a string. Missing URL prevents HTTP protocol from functioning.
- `templates`: Each template must have valid `protocol` and optional `process` array. Invalid templates are dropped.
- `pipelines`: Each pipeline must specify a valid `protocol`. Pipelines referencing dropped templates are also dropped.
- `protocol`: Must be one of: `http`, `log`, or `bus`. Invalid protocols cause that pipeline to be dropped.
- `process`: Must be an array of process block tables, each with a `type` field; additional fields are the block's arguments.

### Warning Handling

When invalid configurations are detected:

1. **Template Failures**: Invalid templates are removed from the config
2. **Dependent Metrics**: Any pipeline referencing a failed template is also removed
3. **Protocol Errors**: Pipelines with invalid protocols are dropped
4. **Graceful Degradation**: Service continues with all valid pipelines; only fails if no valid pipelines remain or `publish_period` is invalid

All dropped metrics and templates are logged with detailed warning messages including:
- Specific validation errors for each dropped item
- Summary of total dropped metrics and templates
- List of affected pipeline names

This allows partial config updates to succeed even if some pipelines are misconfigured.

### Mainflux Config Normalization

The mainflux configuration supports both legacy and current naming conventions:
- `mainflux_id` or `thing_id` (normalized to `thing_id`)
- `mainflux_key` or `thing_key` (normalized to `thing_key`)
- `mainflux_channels` or `channels` (normalized to `channels`)

Channel metadata is automatically injected by scanning channel names:
- Channels containing "data" get `metadata.channel_type = "data"`
- Channels containing "control" get `metadata.channel_type = "events"`

The metrics service merges the mainflux config with the metrics `cloud_url` to build the final HTTP publication config.

## Publication of metrics

Once the publish period has triggered the cache will be purged and all k-v pairs will be converted to a senml representation with correct timestamping. There will be 3 possible protocol for sending of the metrics.

### Log

This method will iterate over the list of senml items and log them using the logging module with info mode (`log.info(key, value)`).

### HTTP

This method will send the senml list to the cloud by building up a cloud config by merging the cloud_url with the mainflux config. The mainflux config is retrieved by loading it from HAL via the `filesystem` capability with the mainflux.cfg file name, this is then decoded from JSON to a Lua table and then normalised (`mainflux_id` -> `thing_id`, `mainflux_key` -> `thing_key`). The mainflux config is of the structure:

```json
{
  "thing_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "thing_key": "550e8400-e29b-41d4-a716-446655440000",
  "channels": [
    {
      "id": "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
      "name": "f47ac10b-58cc-4372-a567-0e02b2c3d479_data",
      "metadata": {
        "channel_type": "data"
      }
    },
    {
      "id": "6ba7b811-9dad-11d1-80b4-00c04fd430c8",
      "name": "f47ac10b-58cc-4372-a567-0e02b2c3d479_control",
      "metadata": {
        "channel_type": "control"
      }
    }
  ],
  "content": "{\"hawkbit\":{\"hawkbit_key\": \"examplehawkbitkey0123456789abcdef\",\"hawkbit_url\": \"https://example.com/hawkbit\"},\"serial\": \"EX1234567890ABCD\",\"networks\":{\"networks\":[{\"name\": \"example-network\",\"ssid\": \"Example WiFi-aB1xY\",\"password\": \"examplepassword123\"}]}}"
}
```
The resulting merger should be formatted into the structure:

```lua
{
  url = "cloud.com",
  data_id = "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
  thing_key = "550e8400-e29b-41d4-a716-446655440000"
}
```

The cloud URI is composed as `cloud.url` + `/http/channels/` + `cloud.data_id` + `/messages`

The authentication header is composed as `Thing ` + `cloud.thing_key`

The body is a json encoding of the senml list

As HTTP publications can fail due to lack of backhaul, boot-time metrics are very important, and publications can cause long blocking time on the fiber they are running on, so we run the HTTP sending in a separate fiber with a queue between the main metrics service fiber and the HTTP fiber.

**Queue Behavior**:
- Fixed capacity: **10 items**
- On queue full: New metrics are **dropped silently** with error log
- No retry mechanism for queue-full conditions (older metrics are preserved)

**Network Failure Retry**:
- When HTTP send fails (network unavailable), the fiber implements exponential backoff
- Sleep duration doubles on each failure: 1s → 2s → 4s → 8s → ... → max 60s
- Retries indefinitely until successful or service shutdown
- Queue-full and network-failure are handled separately: only network failures trigger retry

### Bus

For testability a bus protocol should be provided which will publish the metrics under the topic
`svc/metrics/<key>` for example `svc/metrics/modem/1/sim`. The payload will just be the value and timestamp of the metric.

## Processing

Each metric goes through a processing pipeline which can be composed of a variable amount of process blocks or none at all.

### Pipeline Architecture

The metrics service uses a **shared pipeline with per-endpoint state** model:
- Each configured pipeline (from config) is instantiated **once** as a processing pipeline object
- Each unique metric endpoint (topic path) gets its own **state table**
- The same pipeline logic processes metrics from different endpoints using different state tables
- This allows pipeline code reuse while maintaining isolated state per endpoint

**State Isolation**: A metric published to namespace `network.wan.rx_bytes` and another to namespace `network.lan.rx_bytes` use the same pipeline logic but maintain separate DiffTrigger/DeltaValue state, preventing cross-endpoint interference.

All process blocks and the pipeline itself have an interface to reset state when a value has been published. The pipeline and blocks are logic and config only; they require a state table as input for each invocation.

### ProcessPipeline

The process pipeline contains all processing blocks and runs them sequentially until either:
1. A block returns a short-circuit flag (stops processing early)
2. All blocks complete successfully

The pipeline returns: `(value, short_circuit_flag, error)`

**Short-Circuit Behavior**: When a processing block returns `short_circuit = true`, the pipeline immediately stops processing and the metric is **not stored or published**. This is intentional control flow (e.g., DiffTrigger suppressing unchanged values), not an error condition.

**Reset Behavior**: The pipeline only resets individual block state if a complete run was achieved (no short-circuit). This ensures state is only updated when metrics are actually published.

**Metric Storage Structure**: Successfully processed metrics are stored in a nested structure: `metric_values[protocol][endpoint] = {value, time}`, allowing the same endpoint to publish via multiple protocols (e.g., both "http" and "log").

### DiffTrigger

The difference trigger is a block which only outputs a value if the difference between the last output value and the current value hits a threshold. There are 3 different types of threshold:

- `percent`: Only triggers if the current value is a percentage difference of the last output value
- `absolute`: Only triggers if the current value is an absolute difference of the last output value
- `any-change`: Triggers if the current value does not match the last output value

**Arguments** (fields on the process block table, alongside `type`)

- `diff_method`: This can either be `percent`, `absolute` or `any-change`
- `initial_val`: This is an optional argument to set the previous value before any value has been set. If this value is not set then the block will always output the first value received
- `threshold`: This argument is only for `percent` and `absolute` types, the threshold that must be hit to trigger an output

**Behavior Details**

- **First Value**: The first value received always publishes (triggers) regardless of threshold, unless `initial_val` is specified
- **Reset**: DiffTrigger state is **not affected by reset** - it maintains `last_val` across publish cycles
- **Short-Circuit**: When threshold is not met, returns `short_circuit = true` to prevent publishing

### TimeTrigger

The time trigger outputs a value only once a certain time period has elapsed since the last value output. Uses monotonic time to ensure immunity to system clock changes.

**Arguments** (fields on the process block table, alongside `type`)
- `duration`: the time between value outputs (seconds)

**Behavior Details**

- **Timing**: Timer is reset after each successful output, ensuring periodic publishing every `duration` seconds
- **Reset**: TimeTrigger state is **not affected by reset** - timeout persists across publish cycles
- **Short-Circuit**: When timeout has not expired, returns `short_circuit = true` to suppress output

### DeltaValue

The delta value block always outputs the difference between the last published value and the current value. This is useful for converting cumulative counters into per-period deltas.

**Arguments**

- `initial_val`: An optional initial value to compare the first values to before the first publish, if this is not set the default is 0

**Behavior Details**

- **Calculation**: Returns `current_value - last_published_value`
- **Reset**: On reset, sets `last_val = current_val` (resets to the current value, not zero)
- **Reset Trigger**: Only resets after a successful publish cycle (when pipeline completes without short-circuit)
- **Always Publishes**: Does not short-circuit; always returns a delta value

## Timestamping

Each metric must have an accurate time stamp. As the time at boot will be incorrect until the time service has done a ntp time sync, the metrics service must hold metrics with a relative timestamp which can be converted into a real timestamp once both time has been synced and the publish cache is ready to publish (via the publish period).

### NTP Sync Dependency

The metrics service **blocks all publishing** until NTP time synchronization is confirmed:

- Service subscribes to `{'svc', 'time', 'synced'}` bus topic
- When `synced = true` is received:
  - **First sync**: Calculates base time offset and schedules first publish
  - **Subsequent syncs**: Continues using existing offset
- When `synced = false` is received:
  - Publishing is suspended indefinitely
  - Publish timer is disabled (`next_publish_time = infinity`)
  - Metrics continue to be collected but not published

### Time Conversion

We can convert between relative and real time by using monotonic time stamps on the metrics and holding the monotonic time that the ntp sync was done as well as the real time that the sync was done.

**Base Time Calculation** (on first NTP sync):
- `base_real = current_realtime - (current_monotime - initial_monotime)`
- This calculates what the real time was at the initial monotonic reference point

**Metric Timestamp Conversion** (at publish time):
- `metric_timestamp_ms = floor(base_real + (metric_monotime - base_monotime)) * 1000`
- This converts the metric's monotonic timestamp to real time in milliseconds

**Important**: If NTP sync is lost and regained, the original base time offset is preserved rather than recalculated. This ensures timestamp consistency across sync interruptions.

## Testing

Current automated coverage is in `tests/test_metrics.lua`.

Run command:

```bash
cd tests && luajit test_metrics.lua
```

Covered test groups:

- **Processing blocks (`TestProcessing`)**
  - `DiffTrigger` behavior for `absolute`, `percent`, and `any-change`
  - `DeltaValue` behavior and reset semantics
  - `ProcessPipeline` sequencing, reset, and short-circuit behavior

- **Config module (`TestConfig`)**
  - `validate_http_config` valid + invalid inputs
  - `merge_config` recursive merge behavior
  - `apply_config` builds valid pipeline maps
  - `validate_config` hard rejection (`publish_period <= 0`)
  - `validate_config` warning path for invalid protocol
  - invalid template propagation to dependent pipeline warnings

- **SenML encoder (`TestSenML`)**
  - encode number/string/boolean/time records
  - reject unsupported value types
  - `encode_r` flattening behavior for nested keys

- **HTTP publisher module (`TestHttpModule`)**
  - `start_http_publisher` builds expected HTTP request shape
  - verifies method/header/body composition via mocked `http.request`

- **Service-level behavior (`TestMetricsService`)**
  - bus protocol publish end-to-end
  - namespace override routing/topic mapping
  - unknown metrics are dropped
  - `DiffTrigger` suppresses unchanged values
  - `DeltaValue` emits per-period deltas
  - config update replaces active pipelines
  - per-endpoint state isolation across namespaces
  - HTTP protocol pipeline enqueues expected Mainflux payload

Notes:

- Service tests use virtual time helpers from `tests/test_utils/virtual_time.lua` and `tests/test_utils/time_harness.lua`.
- Service tests subscribe to `{'svc','metrics','#'}` and intentionally filter out `status` lifecycle messages when asserting metric payload publications.







