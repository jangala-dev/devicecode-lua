# Metrics Service Roadmap

## Executive Summary

The metrics service is functional but suffers from architectural complexity and poor maintainability. This roadmap prioritizes improvements to simplify the codebase, reduce config from ~2400 lines to ~200 lines, and improve observability.

**Key Goals:**
- Unify dual-cache architecture into single cache
- Eliminate config duplication with templates and patterns
- Add observability for debugging production issues
- Improve HTTP retry reliability
- Standardize pipeline input format

---

## Phase 1: Core Architecture

**Dependencies:** None - these are foundational changes that must happen first.

### 1. Unified Cache Architecture ✅

**Why:** Dual-cache system (ActionCache + TimedCache) creates unnecessary complexity.

**What:** Single cache managing both pipelines and publish buffering.

**Implementation:**
```lua
---@class MetricsCache
---@field pipelines table<string, ProcessPipeline>
---@field publish_buffer table
---@field next_publish_deadline number
---@field publish_period number

function MetricsCache:process_metric(endpoint, value)
    local pipeline = self:get_or_create_pipeline(endpoint)
    local val, short_circuit, err = pipeline:run(value)

    if not short_circuit and not err then
        self:buffer_for_publish(endpoint, val)
    end

    return val, short_circuit, err
end

function MetricsCache:get_and_reset_publish_buffer()
    local data = self.publish_buffer
    self.publish_buffer = {}
    self.next_publish_deadline = sc.monotime() + self.publish_period
    return data
end
```

**Files:**
- Remove: `action_cache.lua`, `timed_cache.lua`
- Create: `cache.lua`
- Update: `metrics.lua`

**Success Criteria:**
- Code complexity reduced (fewer cache coordination bugs)

---

### 2. Pipeline Templates ✅

**Why:** Config has massive duplication (2400 lines, mostly repeated pipeline definitions).

**What:** Define reusable pipeline templates.

**Before:**
```json
"net/adm/rx_bytes": {
  "protocol": "http",
  "process": [
    {"type": "DiffTrigger", "diff_method": "percent", "threshold": 5, "initial_val": 0},
    {"type": "DeltaValue"}
  ]
}
// ... repeated 40+ times
```

**After:**
```json
"metrics": {
  "pipeline_templates": {
    "network_counter": {
      "protocol": "http",
      "process": [
        {"type": "DiffTrigger", "diff_method": "percent", "threshold": 5, "initial_val": 0},
        {"type": "DeltaValue"}
      ]
    }
  },
  "collections": {
    "net/adm/rx_bytes": {"template": "network_counter"},
    "net/adm/tx_bytes": {"template": "network_counter"}
    // ... 40 lines instead of 2400
  }
}
```

**Implementation:**
1. Parse `pipeline_templates` section first
2. When building pipelines, resolve `template` field
3. Allow per-collection overrides: `{"template": "network_counter", "threshold": 10}`

**Files:**
- Update: `metrics.lua` (_handle_config, _build_metric_pipeline)

**Success Criteria:**
- Existing configs still work
- New template-based configs tested
- Config file size reduced by ~70%

---

### 3. Configuration Validation ✅

**Why:** Validation is scattered, error messages are poor.

**What:** Centralized validation with clear error messages.

**Implementation:**
```lua
-- config_validator.lua
local schemas = {
    metrics_config = {
        required = {"publish_cache", "collections"},
        fields = {
            publish_cache = {
                required = {"period"},
                fields = {period = {type = "number", min = 1}}
            },
            pipeline_templates = {
                type = "table",
                validate_each = function(name, template)
                    return validate_template(template)
                end
            },
            collections = {
                type = "table",
                required = true,
                validate_each = function(endpoint, config)
                    if not (config.template or config.process) then
                        return false, "Collection must have 'template' or 'process'"
                    end
                    return true
                end
            }
        }
    }
}

function validate_config(config)
    -- Returns (ok, list_of_errors)
    local ok, errors = validate_against_schema(config, schemas.metrics_config)
    return ok, errors
end
```

**Files:**
- Create: `metrics/config_validator.lua`
- Update: `metrics.lua` (_handle_config)

**Success Criteria:**
- Invalid configs rejected with helpful error messages
- All validation logic in one place
- Unit tests for validation

---

### 4. Testing Infrastructure

**Why:** No tests for metrics service. Refactoring is risky without tests.

**What:** Unit and integration tests.

**Test Coverage:**
- Pipeline processing (DiffTrigger, DeltaValue, TimeTrigger)
- Template resolution
- Config validation
- Cache behavior
- SenML encoding
- Pattern matching (Phase 2)

**Files:**
- Create: `tests/test_metrics_service.lua`
- Create: `tests/test_metrics_pipelines.lua`
- Create: `tests/test_metrics_config.lua`

**Success Criteria:**
- ~100% code coverage
- All processing blocks have tests
- Config validation fully tested

---

## Phase 2: Config Simplification

**Dependencies:** Phase 1 must be complete (templates need validation, patterns need unified cache).

### 5. Pattern-Based Collections

**Why:** Even with templates, need to list each endpoint explicitly.

**What:** Use patterns like `net/(adm|jan|mdm0|mdm1|wan)/rx_bytes` to match multiple endpoints.

**Before (with templates):**
```json
"collections": {
  "net/adm/rx_bytes": {"template": "network_counter"},
  "net/jan/rx_bytes": {"template": "network_counter"},
  "net/mdm0/rx_bytes": {"template": "network_counter"},
  "net/mdm1/rx_bytes": {"template": "network_counter"},
  "net/wan/rx_bytes": {"template": "network_counter"}
  // ... 40 total entries
}
```

**After (with patterns):**
```json
"collections": {
  "net/(adm|jan|mdm0|mdm1|wan)/(rx_bytes|tx_bytes|rx_packets|tx_packets|rx_dropped|tx_dropped|rx_errors|tx_errors)": {
    "template": "network_counter"
  }
  // 1 line instead of 40!
}
```

**Implementation:**

Pattern matcher converts alternations to wildcards for subscriptions:
- `net/(adm|jan)/rx_bytes` → subscribe to `net/+/rx_bytes`
- Pattern matcher filters out unwanted matches

```lua
function metrics_service:_pattern_to_subscription(pattern_str)
    local sub_parts = {}
    for part in pattern_str:gmatch("[^/]+") do
        if part == "+" or part:match("%(.*|.*%)") then
            table.insert(sub_parts, "+")  -- Any wildcard/alternation → +
        else
            table.insert(sub_parts, part)
        end
    end
    return sub_parts
end
```

**Files:**
- Create: `metrics/pattern_matcher.lua`
- Update: `metrics.lua` (_setup_subscriptions)

**Success Criteria:**
- Patterns work with alternations `(a|b|c)` and wildcards `+`
- Pattern warnings for unused patterns
- Config reduced to ~50 collection entries (from 400+)

---

### 6. Metric Envelope Standard

**Why:** Processing blocks need context (endpoint, timestamp, metadata) not just raw values. This enables building more powerful context-aware processing blocks.

**What:** Standardize pipeline input as envelope structure instead of raw values:

```lua
---@class MetricEnvelope
---@field value any The metric value (number, string, boolean)
---@field endpoint string[] Bus topic as array: {"net", "adm", "rx_bytes"}
---@field timestamp number Unix timestamp in milliseconds
---@field metadata table? Optional metadata (unit, source, etc.)
```

**Flow:**
```
Bus Message → Wrap in Envelope → Pipeline → Publish Buffer → SenML Encode → HTTP
```

SenML encoding still happens once at publish time, not before processing.

**Benefits:**
- **Strongly typed input** - Processing blocks know exactly what they receive
- **Rich context** - Blocks can make decisions based on endpoint, time, metadata
- **Composable** - Envelope passes through pipeline, each block can read/modify
- **Backward compatible** - Support both envelopes and raw values during migration
- **No encoding overhead** - SenML only at publish time, not in pipeline
- **Enables advanced blocks:**
  - `RateLimiter` - time-based filtering using timestamp
  - `EndpointFilter` - filter by endpoint pattern
  - `ValueTransform` - context-aware transformations
  - `AggregateWindow` - time-window aggregation

**Implementation:**

1. **Create envelopes in main loop:**
```lua
metric_op = metric_sub:next_msg_op():wrap(function(metric_msg)
    local raw_value = metric_msg.payload
    if metric_config.field then
        raw_value = raw_value[metric_config.field]
    end

    local envelope = {
        value = raw_value,
        endpoint = metric_msg.topic,
        timestamp = math.floor(sc.realtime() * 1000),
        metadata = metric_config.metadata or {}
    }

    return pipeline:run(envelope)
end)
```

2. **Update processing blocks (backward compatible):**
```lua
function DiffTrigger:run(input)
    -- Extract value from envelope or use raw value
    local value = type(input) == "table" and input.value or input

    self.curr_val = value
    if self.diff_method(self.curr_val, self.last_val, self.threshold) then
        self.last_val = value

        -- Return envelope if we received one, otherwise raw value
        if type(input) == "table" then
            input.value = value
            return input, false, nil
        end
        return value, false, nil
    end
    return nil, true, nil
end
```

3. **Update SenML encoder to handle envelopes:**
```lua
local function encode_r(base_topic, values, output)
    for k, v in pairs(values) do
        -- ... topic construction ...

        if type(v) == 'table' and not (v.value and v.time) then
            encode_r(topic, v, output)
        else
            -- Handle both envelope {value, timestamp, metadata} and old format
            local value_to_encode = v.value or v
            local time_to_encode = v.timestamp or v.time

            local senml_obj, err = encode(topic, value_to_encode, time_to_encode)
            if err then return nil, err end

            -- Include metadata if present
            if type(v) == 'table' and v.metadata and v.metadata.unit then
                senml_obj.u = v.metadata.unit
            end

            table.insert(output, senml_obj)
        end
    end
    return output, nil
end
```

4. **Example advanced processing block:**
```lua
---@class RateLimiter: Process
---@field min_interval number Minimum milliseconds between outputs
---@field last_timestamp number Last time we output a value
local RateLimiter = {}

function RateLimiter.new(config)
    local self = setmetatable({}, RateLimiter)
    self.min_interval = config.interval or 5000  -- 5 seconds default
    self.last_timestamp = 0
    return self
end

function RateLimiter:run(envelope)
    local time_since_last = envelope.timestamp - self.last_timestamp

    if time_since_last >= self.min_interval then
        self.last_timestamp = envelope.timestamp
        return envelope, false, nil
    end

    return nil, true, nil  -- Short-circuit
end
```

**Migration Path:**
1. Add envelope support to processing blocks (backward compatible)
2. Start wrapping new metrics in envelopes
3. Test with subset of collections
4. Roll out to all collections
5. Remove raw value support after full migration

**Files:**
- Update: `processing.lua` (all process blocks)
- Update: `senml.lua` (handle envelopes)
- Update: `metrics.lua` (create envelopes)
- Create: `metrics/advanced_blocks.lua` (RateLimiter, etc.)

**Success Criteria:**
- Backward compatible with raw values
- All existing processing blocks work with envelopes
- New envelope-aware blocks implemented and tested
- SenML encoding handles both formats
- No performance regression

---

### 7. Cache-Level Concatenation (Buffering)

**Why:** Need to batch rare events (e.g., state changes) to reduce HTTP request overhead while preserving all values with correct timestamps.

**What:** Per-collection buffer mode that accumulates values between publish periods.

**Config:**
```json
{
  "metrics": {
    "publish": {
      "period": 300  // Publish every 5 minutes
    },
    "collections": {
      "wifi/clients/+/state": {
        "protocol": "http",
        "process": [{"type": "AnyChange"}],
        "buffer": "concat"  // Accumulate all changes
      },
      "net/adm/rx_bytes": {
        "protocol": "http",
        "process": [{"type": "DiffTrigger"}],
        "buffer": {
          "mode": "concat",
          "max_items": 50  // Optional: flush early if too many
        }
      },
      "modem/signal/rssi": {
        "protocol": "http",
        "buffer": "single"  // Default: latest value only
      }
    }
  }
}
```

**Implementation:**

```lua
function metrics_service:_handle_metric(metric, msg)
    -- ... pipeline processing ...

    if not short then
        self.metric_values[protocol] = self.metric_values[protocol] or {}
        local now = sc.monotime()

        local buffer_config = metric.buffer or {mode = "single"}
        if type(buffer_config) == "string" then
            buffer_config = {mode = buffer_config}
        end

        if buffer_config.mode == "concat" then
            -- Initialize concat buffer if needed
            if not self.metric_values[protocol][str_endpoint] then
                self.metric_values[protocol][str_endpoint] = {
                    mode = "concat",
                    items = {},
                    first_time = now
                }
            end

            -- Add to buffer
            local buffer = self.metric_values[protocol][str_endpoint]
            table.insert(buffer.items, {
                value = ret,
                time = now
            })
        else
            -- Default single-value mode (replace previous)
            self.metric_values[protocol][str_endpoint] = {
                mode = "single",
                value = ret,
                time = now
            }
        end
    end
end
```

**SenML Encoder Update:**
```lua
local function encode_r(base_topic, values, output)
    for k, v in pairs(values) do
        local topic = construct_topic(base_topic, k)

        -- Check if it's a concat buffer
        if v.mode == "concat" then
            -- Flatten buffer items into multiple SenML records
            for _, item in ipairs(v.items) do
                local senml_obj, err = encode(topic, item.value, item.time)
                if err then return nil, err end
                table.insert(output, senml_obj)
            end
        else
            -- Single value {value, time}
            local senml_obj, err = encode(topic, v.value, v.time)
            if err then return nil, err end
            table.insert(output, senml_obj)
        end
    end
    return output, nil
end
```

**HTTP Output (Flattened):**
```json
[
  {"n": "wifi.clients.state", "vs": "connected", "t": 1234567890.000},
  {"n": "wifi.clients.state", "vs": "disconnected", "t": 1234567895.123},
  {"n": "wifi.clients.state", "vs": "connected", "t": 1234567900.456},
  {"n": "net.adm.rx_bytes", "v": 1024, "t": 1234567905.000}
]
```

**Benefits:**
- **Reduces HTTP overhead** - 1 request instead of N for rare events
- **Preserves temporal accuracy** - Each value keeps original timestamp
- **Standard SenML** - No custom array handling
- **Composable** - Works with any processing blocks
- **Per-metric control** - Mix single and concat modes

**Use Cases:**
- ✅ State changes: `AnyChange` + concat to batch events
- ✅ Threshold monitoring: `DiffTrigger` + concat for history
- ✅ Raw value collection: No processing + concat
- ⚠️ Not recommended with `DeltaValue` (state reset issues)

**Naming:**
- **`publish.period`**: Global publish timer (service-level)
- **`buffer`**: Per-metric accumulation mode (collection-level)

**Files:**
- Update: `metrics.lua` (_handle_metric, value storage)
- Update: `senml.lua` (handle concat buffers)
- Update: `config.lua` (rename publish_cache → publish, add buffer validation)

**Success Criteria:**
- Single and concat modes work correctly
- SenML flattens concat buffers with correct timestamps
- Config validation ensures buffer compatibility
- No impact on single-mode performance

---

## Phase 3: Observability

**Dependencies:** Phase 1 complete (need unified cache and pipelines to instrument).

### 7. Pipeline Instrumentation

**Why:** No visibility into pipeline behavior. Can't debug "why isn't this publishing?"

**What:** Add stats tracking to pipelines.

```lua
---@class PipelineStats
---@field total_runs number
---@field successful_runs number
---@field short_circuits number
---@field errors number
---@field last_run_time number
---@field last_success_time number
---@field last_error string?

function ProcessPipeline:run(value)
    self.stats.total_runs = self.stats.total_runs + 1
    self.stats.last_run_time = sc.realtime()

    local val, short, err = self:_execute_pipeline(value)

    if err then
        self.stats.errors = self.stats.errors + 1
        self.stats.last_error = err
    elseif short then
        self.stats.short_circuits = self.stats.short_circuits + 1
    else
        self.stats.successful_runs = self.stats.successful_runs + 1
        self.stats.last_success_time = sc.realtime()
    end

    return val, short, err
end
```

**Files:**
- Update: `processing.lua` (ProcessPipeline class)

**Success Criteria:**
- Every pipeline tracks its stats
- Stats accessible via `pipeline:get_stats()`

---

### 8. Health Metrics Publication

**Why:** Need to monitor the metrics service itself.

**What:** Publish service health to bus every 30 seconds.

```lua
function metrics_service:_publish_health()
    local health = {
        service_uptime = sc.realtime() - self.start_time,
        active_pipelines = table_count(self.cache.pipelines),
        http_publisher = {
            queue_size = self.http_send_q:size(),
            total_sent = self.http_stats.total_sent,
            total_failed = self.http_stats.total_failed,
            last_success_ago = sc.realtime() - self.http_stats.last_success_time
        },
        pipeline_stats = self:_collect_pipeline_stats()
    }
    self.conn:publish({"metrics", "health"}, health)
end
```

**Use Case:**
```bash
# Debug why metrics aren't publishing
$ ubus subscribe metrics.health
{
  "pipeline_stats": {
    "net/adm/rx_bytes": {
      "total_runs": 150,
      "successful_runs": 3,    # Only 2% success!
      "short_circuits": 147     # DiffTrigger threshold too high
    }
  }
}
```

**Files:**
- Update: `metrics.lua` (_main, add health timer)

**Success Criteria:**
- Health published every 30 seconds
- Includes pipeline stats, HTTP stats, queue stats
- Useful for debugging production issues

---

### 9. Per-Collection Debug Mode

**Why:** Need detailed debug info for specific problematic endpoints.

**What:** Optional debug flag in config.

```json
"collections": {
  "net/adm/rx_bytes": {
    "template": "network_counter",
    "debug": true  // Publish detailed debug info
  }
}
```

Debug info published to `metrics/debug/net/adm/rx_bytes`:
```lua
{
  input_value = 1000,
  output_value = 50,
  short_circuited = false,
  pipeline_stats = {...},
  timestamp = 1234567890
}
```

**Files:**
- Update: `metrics.lua` (metric processing loop)

**Success Criteria:**
- Debug mode configurable per-collection
- Debug output useful for troubleshooting
- No performance impact when disabled

---

## Phase 4: Reliability

**Dependencies:** Phase 3 recommended (hooks need instrumentation for debugging).

### 10. Improved HTTP Retry

**Why:** 10-item queue drops metrics when full.

**Current:** HTTP sender has exponential backoff (good!) but queue is fixed at 10 items (bad!)

**What:** Larger retry buffer with priority-based eviction.

```lua
local RetryBuffer = {
    max_size = 50,  -- 5x larger
    items = {},
    priorities = {
        critical = {"session_start", "session_end"},
        high = {"modem_state"},
        normal = {} -- everything else
    }
}

function RetryBuffer:add(item)
    if #self.items >= self.max_size then
        self:evict_lowest_priority()
    end
    table.insert(self.items, item)
end

function RetryBuffer:evict_lowest_priority()
    -- Remove oldest non-critical item
    for i, item in ipairs(self.items) do
        if not self:is_critical(item) then
            table.remove(self.items, i)
            log.warn("Evicted metric: " .. item.endpoint)
            return
        end
    end
    -- All critical, remove oldest
    table.remove(self.items, 1)
end
```

**Files:**
- Update: `http.lua` (retry buffer)
- Update: `metrics.lua` (configure priorities)

**Success Criteria:**
- Critical metrics (session_start/end) never dropped
- Buffer handles 5-10 minute outages
- Eviction warnings logged

---

### 11. Event Hooks

**Why:** Need special handling for critical metrics that fail.

**What:** Configurable hooks for lifecycle events.

```json
"collections": {
  "wifi/clients/+/sessions/+/session_start": {
    "protocol": "http",
    "hooks": {
      "on_http_fail": "persist_to_disk",  // Never lose session starts
      "on_publish": "log_critical"
    }
  }
}
```

```lua
local hook_handlers = {
    persist_to_disk = function(endpoint, data)
        -- Write to /tmp/metrics_failed.log for manual recovery
        local file = io.open("/tmp/metrics_failed.log", "a")
        file:write(os.time() .. "|" .. endpoint .. "|" .. json.encode(data) .. "\n")
        file:close()
    end,
    log_critical = function(endpoint, data)
        log.error("[CRITICAL] " .. endpoint .. " published")
    end
}
```

**Files:**
- Create: `metrics/hooks.lua`
- Update: `metrics.lua` (execute hooks)

**Success Criteria:**
- Hooks configured per-collection
- Failed critical metrics persisted to disk
- Hook errors don't crash service

---

### 12. Graceful Degradation

**Why:** Invalid config for one collection shouldn't kill entire service.

**What:** Load valid collections, log errors for invalid ones, continue operating.

```lua
function metrics_service:_handle_config(config)
    local valid_collections = {}
    local errors = {}

    for endpoint, collection_config in pairs(config.collections) do
        local ok, err = self:_validate_and_build_collection(endpoint, collection_config)
        if ok then
            valid_collections[endpoint] = collection_config
        else
            table.insert(errors, string.format("%s: %s", endpoint, err))
        end
    end

    if #errors > 0 then
        log.error("Failed to load some collections:\n" .. table.concat(errors, "\n"))
    end

    if #valid_collections == 0 then
        return "No valid collections in config"
    end

    self:_setup_subscriptions(valid_collections)
end
```

**Files:**
- Update: `metrics.lua` (_handle_config)

**Success Criteria:**
- Service continues with partial config
- All errors logged clearly
- Config updates can fix broken collections

---

## Implementation Ordering

**Strict Dependencies:**
1. **Phase 1 items 1-4** must complete before Phase 2
   - Unified cache required for pattern-based collections
   - Templates required for pattern matching
   - Validation required for safe config changes
   - Tests required before any refactoring

2. **Phase 2 item 5** (patterns) depends on Phase 1 item 2 (templates)
   - Patterns reference templates, so templates must exist first

3. **Phase 3** can start after Phase 1 completes
   - Instrumentation needs unified cache and pipelines
   - Independent of Phase 2

4. **Phase 4** can happen anytime after Phase 1
   - HTTP retry improvements independent
   - Hooks benefit from Phase 3 instrumentation but not required

**Flexible Ordering:**
- Phase 2 and Phase 3 can be done in parallel after Phase 1
- Phase 4 items can be done independently of each other
- Phase 2 item 6 (envelopes) can be done anytime, independent of other phases

---

## Success Metrics

**Before:**
- Config: ~2400 lines
- Cache: 2 separate systems
- Tests: 0
- Observability: None (can't debug production issues)
- Reliability: Drops metrics when queue fills

**After:**
- Config: ~200 lines (90% reduction)
- Cache: 1 unified system
- Tests: 80%+ coverage
- Observability: Health metrics, pipeline stats, debug mode
- Reliability: Priority-based retry, hooks for critical metrics

**Key Wins:**
1. **10x smaller configs** - easier to maintain, less error-prone
2. **Better debugging** - can see why metrics aren't publishing
3. **More reliable** - critical metrics never lost
4. **Simpler code** - unified cache, centralized validation
5. **Safer changes** - comprehensive test coverage

---

## Implementation Constraints

**Backward Compatibility:**
- Must support both old and new config formats during transition
- All changes must be backward compatible
- No breaking changes without migration path

**Testing Requirements:**
- Unit tests required before merging any phase
- Integration tests for full pipeline
- Must test on dev devices before production rollout

**Deployment Strategy:**
- Gradual rollout (dev → staging → production)
- Rollback plan required for each phase
- Config validation errors must not crash service

**Code Quality:**
- No inheritance patterns (team requirement)
- Centralized validation
- Clear error messages
- Documentation for each phase

---

## Future Enhancements (Post-Phase 4)

- Disk-persistent retry buffer (survive reboots)
- Metrics aggregation (reduce cloud bandwidth)
- Dynamic pipeline updates (no service restart)
- Multi-protocol publishing (MQTT, CoAP)
- Metric sampling (reduce processing load)

---

## Appendix: Memory-Efficient Pipeline Sharing (Advanced)

### Problem Statement

Currently, each endpoint gets its own cloned pipeline instance to maintain independent state. With 100 endpoints using identical pipelines, you have 100 copies in memory. While templates reduce config size, they don't reduce runtime memory footprint.

**Example:**
```lua
-- Current approach: Each endpoint has its own pipeline
self.pipelines["net/adm/rx_bytes"] = base_pipeline:clone()  -- DiffTrigger state: last_val, threshold
self.pipelines["net/adm/tx_bytes"] = base_pipeline:clone()  -- Independent copy
self.pipelines["net/jan/rx_bytes"] = base_pipeline:clone()  -- Independent copy
-- ... 97 more clones
```

**Memory Cost:**
- 100 endpoints × (DiffTrigger + TimeTrigger + DeltaValue) = ~100 state objects
- Each state object: ~100 bytes
- Total: ~10KB (not huge, but adds up with more process blocks)

### Proposed Solution: Stateless Pipelines with External State

**Core Idea:** Separate pipeline logic (stateless, shareable) from pipeline state (per-endpoint).

#### Architecture

```lua
---@class StatelessPipeline
---@field process_blocks Process[] Shared logic, no state
local StatelessPipeline = {}

function StatelessPipeline:run(value, state)
    local val = value
    local short = false
    local err = nil

    for i, process in ipairs(self.process_blocks) do
        -- Pass per-endpoint state to each process block
        val, short, err = process:run(val, state[i])
        if err or short then break
    end

    return val, short, err
end

---@class PipelineState
---@field states table[] Array of per-block state objects
local PipelineState = {}

function PipelineState.new(pipeline_template)
    local states = {}
    for i, process_block in ipairs(pipeline_template.process_blocks) do
        -- Each block initializes its own state
        states[i] = process_block:create_state()
    end
    return setmetatable({states = states}, PipelineState)
end
```

#### Process Block Refactor

**Before (Stateful):**
```lua
---@class DiffTrigger: Process
---@field threshold number
---@field last_val number
---@field curr_val number
local DiffTrigger = {}

function DiffTrigger:run(value)
    self.curr_val = value
    if self.diff_method(self.curr_val, self.last_val, self.threshold) then
        self.last_val = value
        return value, false, nil
    end
    return nil, true, nil
end

function DiffTrigger:clone()
    -- Full object copy
    return DiffTrigger.new(self.config)
end
```

**After (Stateless with External State):**
```lua
---@class DiffTrigger: Process
---@field threshold number (immutable config)
---@field diff_method function (immutable logic)
local DiffTrigger = {}

---@class DiffTriggerState
---@field last_val number
---@field curr_val number
---@field empty boolean

function DiffTrigger:create_state()
    return {
        last_val = self.initial_val or 0,
        curr_val = self.initial_val,
        empty = (self.initial_val == nil)
    }
end

function DiffTrigger:run(value, state)
    state.curr_val = value
    if state.empty or self.diff_method(state.curr_val, state.last_val, self.threshold) then
        state.last_val = value
        state.empty = false
        return value, false, nil
    end
    return nil, true, nil
end

function DiffTrigger:reset(state)
    -- Reset only state, not the process block itself
end
```

#### Cache Implementation

```lua
local metrics_cache = {
    shared_pipelines = {},  -- Template name -> StatelessPipeline (SHARED)
    endpoint_states = {}    -- Endpoint -> PipelineState (PER-ENDPOINT)
}

function metrics_cache:process_metric(endpoint, template_name, value)
    -- Get shared pipeline (created once per template)
    local pipeline = self.shared_pipelines[template_name]
    if not pipeline then
        pipeline = self:build_shared_pipeline(template_name)
        self.shared_pipelines[template_name] = pipeline
    end

    -- Get per-endpoint state (lazy init)
    local state = self.endpoint_states[endpoint]
    if not state then
        state = PipelineState.new(pipeline)
        self.endpoint_states[endpoint] = state
    end

    -- Run shared pipeline with endpoint-specific state
    return pipeline:run(value, state.states)
end
```

### Memory Savings

**Before:**
```
100 endpoints × (DiffTrigger + TimeTrigger + DeltaValue) instances
= 100 × 3 objects = 300 objects
= ~30KB
```

**After:**
```
Shared: 1 template × 3 process blocks = 3 objects (~1KB)
State: 100 endpoints × 3 state objects = 300 state objects (~15KB)
Total: ~16KB (47% reduction)
```

**Scaling Benefits:**
- 1000 endpoints with 5 templates: 1000 clones → 5 shared + 1000 states
- Memory reduction increases with more endpoints sharing templates
- Better CPU cache locality (shared logic is hot in cache)

### Trade-offs

**Pros:**
- ✅ Significant memory reduction (30-50% for typical configs)
- ✅ Better cache locality (hot pipeline code shared)
- ✅ Clearer separation: logic vs state
- ✅ Easier to reason about immutable pipeline logic

**Cons:**
- ❌ More complex implementation (state management)
- ❌ All process blocks must be refactored
- ❌ Slight performance overhead (extra indirection for state access)
- ❌ Harder to debug (state is external to process block)
- ❌ Breaking change (can't be done incrementally)

### Implementation Path

This is a **major refactor** and should only be considered if:
1. Memory usage becomes a production issue (>1000 endpoints)
2. Phase 1-4 are complete and stable
3. Comprehensive tests are in place
4. Team capacity for large refactor

**Estimated Effort:** 2-3 weeks

**Alternative:** If memory is a concern but not critical, consider:
- Lazy pipeline creation (only create when endpoint first publishes)
- Pipeline pooling (reuse pipelines for inactive endpoints)
- Lightweight state (use primitive types, avoid tables where possible)
