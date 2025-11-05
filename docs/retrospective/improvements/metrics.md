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

### 1. Unified Cache Architecture

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

### 2. Pipeline Templates

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

### 3. Configuration Validation

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
- Pipeline composition (blocked - team doesn't want config inheritance)
