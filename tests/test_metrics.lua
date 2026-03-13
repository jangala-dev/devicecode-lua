-- test_metrics.lua
--
-- Service-level tests for the metrics service.
--
-- Each test spins up the full metrics service in a child scope, interacts with
-- it via the bus, and asserts on bus-published results.
--
-- Run standalone: luajit test_metrics.lua

local this_file = debug.getinfo(1, "S").source:match("@?([^/]+)$")
local is_entry_point = arg and arg[0] and arg[0]:match("[^/]+$") == this_file

if is_entry_point then
    package.path = "../vendor/lua-fibers/src/?.lua;"
        .. "../vendor/lua-trie/src/?.lua;"
        .. "../vendor/lua-bus/src/?.lua;"
        .. "../src/?.lua;"
        .. "./test_utils/?.lua;"
        .. package.path
        .. ";/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua"

    _G._TEST = true
end

local luaunit = require 'luaunit'
local fibers  = require 'fibers'
local perform = fibers.perform
local op      = require 'fibers.op'
local busmod  = require 'bus'
local json    = require 'cjson.safe'
local virtual_time = require 'virtual_time'
local time_harness = require 'time_harness'

local processing = require 'services.metrics.processing'
local conf       = require 'services.metrics.config'
local senml      = require 'services.metrics.senml'

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

-- A sample mainflux.cfg payload returned by the mock HAL RPC.
local MAINFLUX_CFG = json.encode({
    thing_key = 'test-thing-key',
    channels  = {
        { id = 'ch-data',    name = 'test_data',    metadata = { channel_type = 'data' } },
        { id = 'ch-control', name = 'test_control', metadata = { channel_type = 'control' } },
    },
})

-- Build a fresh bus and test connection for each test.
local function make_bus()
    return busmod.new({ q_length = 100, s_wild = '+', m_wild = '#' })
end

local function new_test_clock()
    return virtual_time.install({
        monotonic = 0,
        realtime  = 1700000000,
    })
end

local function flush_ticks(max_ticks)
    time_harness.flush_ticks(max_ticks or 20)
end

-- The tests subscribe to {'svc', 'metrics', '#'} so they can match
-- dynamically-keyed output topics such as 'svc.metrics.wan.rx_bytes'.
-- The '#' wildcard also captures the service's own lifecycle messages
-- retained at {'svc', 'metrics', 'status'} (e.g. 'starting', 'running',
-- 'stopped').  The helpers below skip those status messages so assertions
-- only see metric payload publishes.
local function recv_timeout(clock, sub, timeout_s)
    local step = 0.05
    local max_ticks = 20
    local elapsed = 0
    while true do
        while true do
            local ok, msg = time_harness.try_op_now(function() return sub:recv_op() end)
            if not ok then break end
            if msg.topic[3] ~= 'status' then return msg end
        end
        if elapsed >= timeout_s then return nil end
        local advance = math.min(step, timeout_s - elapsed)
        clock:advance(advance)
        time_harness.flush_ticks(max_ticks)
        elapsed = elapsed + advance
    end
end

local function drain_non_status(sub, max_ticks)
    max_ticks = max_ticks or 20
    local messages = {}
    for tick = 1, max_ticks do
        local saw_message = false
        while true do
            local ok, msg = time_harness.try_op_now(function() return sub:recv_op() end)
            if not ok then break end
            saw_message = true
            if msg.topic[3] ~= 'status' then
                messages[#messages + 1] = msg
            end
        end
        if not saw_message or tick == max_ticks then break end
        time_harness.flush_ticks(1)
    end
    return messages
end

-- Start a mock handler for the HAL filesystem read RPC on `bus`.
-- The handler responds with `mainflux_cfg_json` to every request then loops.
-- Returns the child scope so the caller can cancel it after the test.
local function start_mock_hal(test_conn, root_scope)
    local ep = test_conn:bind(
        { 'cap', 'fs', 'configs', 'rpc', 'read' },
        { queue_len = 5 })

    root_scope:spawn(function()
        while true do
            local req, err = perform(ep:recv_op())
            if not req then break end
            -- call_op binds a reply endpoint; deliver to it with publish_one.
            test_conn:publish_one(req.reply_to, { ok = true, reason = MAINFLUX_CFG })
        end
    end)
end

-- Convenience: start the metrics service in its own child scope.
-- Returns the scope so the caller can cancel/join it.
local function start_metrics(bus, root_scope, opts)
    local svc_scope = root_scope:child()
    svc_scope:spawn(function()
        -- Each test needs a fresh require to reset module-level State.
        package.loaded['services.metrics'] = nil
        local metrics = require 'services.metrics'
        local svc_conn = bus:connect()
        metrics.start(svc_conn, opts or { name = 'metrics' })
    end)
    return svc_scope
end

-- Cancel a scope and wait for it to finish.
local function stop_scope(svc_scope)
    svc_scope:cancel('test done')
    perform(svc_scope:join_op())
end

-- A minimal valid metrics config with one bus-protocol pipeline.
local function bus_pipeline_config(metric_name, publish_period, process)
    return {
        publish_period = publish_period or 0.1,
        pipelines = {
            [metric_name] = {
                protocol = 'bus',
                process  = process or {},
            },
        },
    }
end

-- A minimal valid metrics config with one log-protocol pipeline.
local function log_pipeline_config(metric_name, publish_period, process)
    return {
        publish_period = publish_period or 0.1,
        pipelines = {
            [metric_name] = {
                protocol = 'log',
                process  = process or {},
            },
        },
    }
end

-------------------------------------------------------------------------------
-- Unit tests: processing blocks
-------------------------------------------------------------------------------

TestProcessing = {}

function TestProcessing:test_diff_trigger_absolute()
    local trigger = processing.DiffTrigger.new({
        threshold   = 5,
        diff_method = 'absolute',
        initial_val = 10,
    })
    local state = trigger:new_state()

    local val, short, err = trigger:run(12, state)
    luaunit.assertNil(err)
    luaunit.assertTrue(short)  -- diff = 2 < threshold 5, short-circuits

    val, short, err = trigger:run(16, state)
    luaunit.assertNil(err)
    luaunit.assertFalse(short) -- diff = 6 >= threshold 5
    luaunit.assertEquals(val, 16)
end

function TestProcessing:test_diff_trigger_percent()
    local trigger = processing.DiffTrigger.new({
        threshold   = 10,
        diff_method = 'percent',
        initial_val = 100,
    })
    local state = trigger:new_state()

    local val, short, err = trigger:run(105, state)
    luaunit.assertNil(err)
    luaunit.assertTrue(short)  -- 5% < 10% threshold

    val, short, err = trigger:run(115, state)
    luaunit.assertNil(err)
    luaunit.assertFalse(short) -- 15% >= 10% threshold
    luaunit.assertEquals(val, 115)
end

function TestProcessing:test_diff_trigger_any_change()
    local trigger = processing.DiffTrigger.new({
        diff_method = 'any-change',
        initial_val = 10,
    })
    local state = trigger:new_state()

    local val, short, err = trigger:run(10, state)
    luaunit.assertNil(err)
    luaunit.assertTrue(short)   -- same value

    val, short, err = trigger:run(10.1, state)
    luaunit.assertNil(err)
    luaunit.assertFalse(short)  -- changed
    luaunit.assertEquals(val, 10.1)
end

function TestProcessing:test_delta_value()
    local block = processing.DeltaValue.new({ initial_val = 10 })
    local state = block:new_state()

    local val, short, err = block:run(15, state)
    luaunit.assertNil(err)
    luaunit.assertFalse(short)
    luaunit.assertEquals(val, 5)  -- 15 - 10

    block:reset(state)            -- simulate publish: last_val = 15

    val, short, err = block:run(20, state)
    luaunit.assertNil(err)
    luaunit.assertEquals(val, 5) -- 20 - 15
end

function TestProcessing:test_pipeline_run_and_reset()
    local pipeline, err = processing.new_process_pipeline()
    luaunit.assertNil(err)
    pipeline:add(processing.DeltaValue.new({ initial_val = 10 }))

    local state = pipeline:new_state()

    local val, short
    val, short, err = pipeline:run(20, state)
    luaunit.assertNil(err)
    luaunit.assertFalse(short)
    luaunit.assertEquals(val, 10) -- 20 - 10

    pipeline:reset(state)         -- last_val = 20

    val, short, err = pipeline:run(25, state)
    luaunit.assertNil(err)
    luaunit.assertEquals(val, 5)  -- 25 - 20
end

function TestProcessing:test_pipeline_short_circuit()
    local pipeline, err = processing.new_process_pipeline()
    luaunit.assertNil(err)
    pipeline:add(processing.DiffTrigger.new({
        diff_method = 'absolute', threshold = 5, initial_val = 10,
    }))
    pipeline:add(processing.DeltaValue.new({ initial_val = 10 }))

    local state = pipeline:new_state()

    local val, short
    val, short, err = pipeline:run(20, state)  -- diff=10, passes DiffTrigger
    luaunit.assertNil(err)
    luaunit.assertFalse(short)
    luaunit.assertEquals(val, 10) -- DeltaValue: 20-10

    val, short, err = pipeline:run(22, state)  -- diff=2 from last(20), short-circuits
    luaunit.assertNil(err)
    luaunit.assertTrue(short)
end

-------------------------------------------------------------------------------
-- Unit tests: config module
-------------------------------------------------------------------------------

TestConfig = {}

function TestConfig:test_validate_http_config_valid()
    local ok, err = conf.validate_http_config({
        url       = 'http://cloud.example.com',
        thing_key = 'key',
        channels  = { { id = 'ch1', name = 'data' } },
    })
    luaunit.assertTrue(ok)
    luaunit.assertNil(err)
end

function TestConfig:test_validate_http_config_nil()
    local ok, err = conf.validate_http_config(nil)
    luaunit.assertFalse(ok)
    luaunit.assertNotNil(err)
end

function TestConfig:test_validate_http_config_missing_url()
    local ok, err = conf.validate_http_config({ thing_key = 'k', channels = {} })
    luaunit.assertFalse(ok)
    luaunit.assertNotNil(err)
end

function TestConfig:test_merge_config()
    local merged = conf.merge_config(
        { a = 1, nested = { x = 10, y = 20 } },
        { b = 2, nested = { y = 99, z = 30 } }
    )
    luaunit.assertEquals(merged.a, 1)
    luaunit.assertEquals(merged.b, 2)
    luaunit.assertEquals(merged.nested.x, 10)
    luaunit.assertEquals(merged.nested.y, 99) -- overridden
    luaunit.assertEquals(merged.nested.z, 30) -- added
end

function TestConfig:test_apply_config_builds_pipeline()
    local map, period = conf.apply_config({
        publish_period = 30,
        pipelines = {
            rx_bytes = {
                protocol = 'log',
                process  = { { type = 'DeltaValue' } },
            },
        },
    })
    luaunit.assertEquals(period, 30)
    luaunit.assertNotNil(map.rx_bytes)
    luaunit.assertEquals(map.rx_bytes.protocol, 'log')
    luaunit.assertNotNil(map.rx_bytes.pipeline)
end

function TestConfig:test_validate_config_rejects_bad_period()
    local ok, _, err = conf.validate_config({
        publish_period = -1,
        pipelines      = { sim = { protocol = 'log', process = {} } },
    })
    luaunit.assertFalse(ok)
    luaunit.assertNotNil(err)
end

function TestConfig:test_validate_config_warns_bad_protocol()
    local ok, warns = conf.validate_config({
        publish_period = 10,
        pipelines      = { sim = { protocol = 'invalid' } },
    })
    luaunit.assertTrue(ok)
    luaunit.assertTrue(#warns > 0)
end

function TestConfig:test_validate_config_propagates_invalid_template_to_pipeline()
    local ok, warns, err = conf.validate_config({
        publish_period = 10,
        templates = {
            bad_template = {
                protocol = 'invalid',
            },
        },
        pipelines = {
            sim = {
                template = 'bad_template',
            },
        },
    })

    luaunit.assertTrue(ok)
    luaunit.assertNil(err)

    local saw_template_invalid = false
    local saw_metric_uses_invalid_template = false
    local saw_metric_invalid_protocol = false

    for _, w in ipairs(warns) do
        if w.type == 'template'
            and w.endpoint == 'bad_template'
            and string.find(w.msg, "invalid protocol 'invalid'", 1, true)
        then
            saw_template_invalid = true
        end

        if w.type == 'metric'
            and w.endpoint == 'sim'
            and string.find(w.msg, 'uses invalid template [bad_template]', 1, true)
        then
            saw_metric_uses_invalid_template = true
        end

        if w.type == 'metric'
            and w.endpoint == 'sim'
            and string.find(w.msg, "invalid protocol 'invalid'", 1, true)
        then
            saw_metric_invalid_protocol = true
        end
    end

    luaunit.assertTrue(saw_template_invalid)
    luaunit.assertTrue(saw_metric_uses_invalid_template)
    luaunit.assertTrue(saw_metric_invalid_protocol)
end

-------------------------------------------------------------------------------
-- Unit tests: SenML encoder
-------------------------------------------------------------------------------

TestSenML = {}

function TestSenML:test_encode_number()
    local rec, err = senml.encode('cpu', 42.5)
    luaunit.assertNil(err)
    luaunit.assertEquals(rec.n, 'cpu')
    luaunit.assertEquals(rec.v, 42.5)
end

function TestSenML:test_encode_string()
    local rec, err = senml.encode('status', 'ok')
    luaunit.assertNil(err)
    luaunit.assertEquals(rec.vs, 'ok')
end

function TestSenML:test_encode_boolean()
    local rec, err = senml.encode('flag', true)
    luaunit.assertNil(err)
    luaunit.assertEquals(rec.vb, true)
end

function TestSenML:test_encode_with_time()
    local rec, err = senml.encode('t', 1, 1000)
    luaunit.assertNil(err)
    luaunit.assertEquals(rec.t, 1000)
end

function TestSenML:test_encode_invalid_value()
    local rec, err = senml.encode('k', {})
    luaunit.assertNil(rec)
    luaunit.assertNotNil(err)
end

function TestSenML:test_encode_r_flat()
    local recs, err = senml.encode_r('dev', { temp = 23.5, status = 'on' })
    luaunit.assertNil(err)
    luaunit.assertEquals(#recs, 2)
    local names = {}
    for _, r in ipairs(recs) do names[r.n] = r end
    luaunit.assertEquals(names['dev.temp'].v,   23.5)
    luaunit.assertEquals(names['dev.status'].vs, 'on')
end

-------------------------------------------------------------------------------
-- Unit tests: HTTP publisher module
-------------------------------------------------------------------------------

TestHttpModule = {}

function TestHttpModule:test_start_http_publisher_builds_expected_request()
    local original_http_request = package.loaded['http.request']
    local original_http_module  = package.loaded['services.metrics.http']

    local captured = {
        uri = nil,
        method = nil,
        auth = nil,
        content_type = nil,
        expect_header = 'present',
        body = nil,
        timeout = nil,
    }

    package.loaded['http.request'] = {
        new_from_uri = function(uri)
            captured.uri = uri

            local hdr = {}
            local req = {
                headers = {
                    upsert = function(_, k, v) hdr[k] = v end,
                    delete = function(_, k) hdr[k] = nil end,
                },
                set_body = function(_, body)
                    captured.body = body
                end,
                go = function(_, timeout)
                    captured.timeout = timeout
                    captured.method = hdr[':method']
                    captured.auth = hdr['authorization']
                    captured.content_type = hdr['content-type']
                    captured.expect_header = hdr['expect']
                    return {
                        get = function(_, key)
                            if key == ':status' then return '202' end
                            return nil
                        end,
                        each = function()
                            return function() return nil end
                        end,
                    }
                end,
            }

            return req
        end,
    }

    package.loaded['services.metrics.http'] = nil

    local st, _, test_err = fibers.run_scope(function(s)
        local http_mod = require 'services.metrics.http'

        local worker_scope, worker_err = s:child()
        luaunit.assertNotNil(worker_scope, tostring(worker_err))

        local spawn_ok, spawn_err = worker_scope:spawn(function()
            local ch = http_mod.start_http_publisher()

            perform(ch:put_op({
                uri = 'http://localhost:18080/http/channels/ch-data/messages',
                auth = 'Thing test-thing-key',
                body = '[{"n":"sim","vs":"present"}]',
            }))
        end)
        luaunit.assertTrue(spawn_ok, tostring(spawn_err))

        flush_ticks(20)

        luaunit.assertEquals(captured.uri,
            'http://localhost:18080/http/channels/ch-data/messages')
        luaunit.assertEquals(captured.method, 'POST')
        luaunit.assertEquals(captured.auth, 'Thing test-thing-key')
        luaunit.assertEquals(captured.content_type, 'application/senml+json')
        luaunit.assertNil(captured.expect_header)
        luaunit.assertEquals(captured.body, '[{"n":"sim","vs":"present"}]')
        luaunit.assertEquals(captured.timeout, 10)

        worker_scope:cancel('test done')
        perform(worker_scope:join_op())
    end)

    package.loaded['http.request'] = original_http_request
    package.loaded['services.metrics.http'] = original_http_module

    if st ~= 'ok' then
        error(test_err or ('http module scope failed: ' .. tostring(st)))
    end
end

-------------------------------------------------------------------------------
-- Service-level tests
--
-- These tests run the full metrics service in a child scope and exercise it
-- end-to-end via the bus.  Because they call perform() / sleep, they must run
-- inside a fiber (i.e. inside fibers.run or another existing scope+spawn).
-------------------------------------------------------------------------------

TestMetricsService = {}

-- Publish a metric config as a retained message and a raw metric, then verify
-- the processed value is re-published on the bus topic.
function TestMetricsService:test_metric_published_via_bus()
    local clock = new_test_clock()
    local root      = fibers.current_scope()
    local bus       = make_bus()
    local test_conn = bus:connect()

    -- Signal HAL filesystem capability ready (retained).
    test_conn:retain({ 'cap', 'fs', 'configs', 'state' }, 'added')
    start_mock_hal(test_conn, root)

    -- Subscribe to bus-protocol metric output before starting the service.
    local result_sub = test_conn:subscribe(
        { 'svc', 'metrics', '#' },
        { queue_len = 10, full = 'drop_oldest' })

    -- Publish config: simple pass-through pipeline, publish every 0.1 s.
    test_conn:retain({ 'cfg', 'metrics' }, bus_pipeline_config('sim', 0.1))

    local svc_scope = start_metrics(bus, root)
    flush_ticks()

    -- topic[5] = 'sim' must match the pipeline name.
    test_conn:publish(
        { 'obs', 'v1', 'modem', 'metric', 'sim' },
        { value = 'present', namespace = { 'modem', 1, 'sim' } })

    local msg = recv_timeout(clock, result_sub, 0.5)

    luaunit.assertNotNil(msg, 'expected bus publish of sim metric')
    luaunit.assertEquals(msg.payload.value, 'present')

    stop_scope(svc_scope)
    clock:restore()
end

-- When the payload has a `namespace` field it overrides the bus topic used as
-- the SenML key and the output topic.
function TestMetricsService:test_namespace_overrides_topic_key()
    local clock = new_test_clock()
    local root      = fibers.current_scope()
    local bus       = make_bus()
    local test_conn = bus:connect()

    test_conn:retain({ 'cap', 'fs', 'configs', 'state' }, 'added')
    start_mock_hal(test_conn, root)

    local result_sub = test_conn:subscribe(
        { 'svc', 'metrics', '#' },
        { queue_len = 10, full = 'drop_oldest' })

    test_conn:retain({ 'cfg', 'metrics' }, bus_pipeline_config('rx_bytes', 0.1))
    local svc_scope = start_metrics(bus, root)
    flush_ticks()

    -- Publish with a namespace override: topic key becomes 'wan.rx_bytes'.
    test_conn:publish(
        { 'obs', 'v1', 'network', 'metric', 'rx_bytes' },
        { value = 1024, namespace = { 'wan', 'rx_bytes' } })

    local msg = recv_timeout(clock, result_sub, 0.5)

    luaunit.assertNotNil(msg, 'expected bus publish with namespace key')
    -- Output topic should be {'svc', 'metrics', 'wan', 'rx_bytes'}
    luaunit.assertEquals(msg.topic[3], 'wan')
    luaunit.assertEquals(msg.topic[4], 'rx_bytes')
    luaunit.assertEquals(msg.payload.value, 1024)

    stop_scope(svc_scope)
    clock:restore()
end

-- A metric whose name has no matching pipeline must be silently dropped.
function TestMetricsService:test_unknown_metric_dropped()
    local clock = new_test_clock()
    local root      = fibers.current_scope()
    local bus       = make_bus()
    local test_conn = bus:connect()

    test_conn:retain({ 'cap', 'fs', 'configs', 'state' }, 'added')
    start_mock_hal(test_conn, root)

    local result_sub = test_conn:subscribe(
        { 'svc', 'metrics', '#' },
        { queue_len = 10, full = 'drop_oldest' })

    -- Config only knows about 'sim'; we will publish 'rx_bytes'.
    test_conn:retain({ 'cfg', 'metrics' }, bus_pipeline_config('sim', 0.1))
    local svc_scope = start_metrics(bus, root)
    flush_ticks()

    test_conn:publish(
        { 'obs', 'v1', 'network', 'metric', 'rx_bytes' },
        { value = 9999 })

    clock:advance(0.25)
    time_harness.flush_ticks(20)
    local messages = drain_non_status(result_sub)

    luaunit.assertEquals(#messages, 0, 'unexpected publish for unknown metric')

    stop_scope(svc_scope)
    clock:restore()
end

-- A DiffTrigger with any-change suppresses the second publish when the value
-- does not change between publish cycles.
function TestMetricsService:test_difftrigger_suppresses_unchanged_value()
    local clock = new_test_clock()
    local root      = fibers.current_scope()
    local bus       = make_bus()
    local test_conn = bus:connect()

    test_conn:retain({ 'cap', 'fs', 'configs', 'state' }, 'added')
    start_mock_hal(test_conn, root)

    local result_sub = test_conn:subscribe(
        { 'svc', 'metrics', '#' },
        { queue_len = 10, full = 'drop_oldest' })

    test_conn:retain({ 'cfg', 'metrics' }, bus_pipeline_config('sim', 0.1, {
        { type = 'DiffTrigger', diff_method = 'any-change' },
    }))
    local svc_scope = start_metrics(bus, root)
    flush_ticks()

    -- First publish: value 'present' — should pass DiffTrigger.
    test_conn:publish(
        { 'obs', 'v1', 'modem', 'metric', 'sim' },
        { value = 'present' })

    local msg1 = recv_timeout(clock, result_sub, 0.4)
    luaunit.assertNotNil(msg1, 'expected first publish')
    luaunit.assertEquals(msg1.payload.value, 'present')

    -- Second publish: same value — DiffTrigger must suppress it.
    test_conn:publish(
        { 'obs', 'v1', 'modem', 'metric', 'sim' },
        { value = 'present' })

    clock:advance(0.25)
    time_harness.flush_ticks(20)
    local msg2 = nil
    while true do
        local ok, m = time_harness.try_op_now(function() return result_sub:recv_op() end)
        if not ok then break end
        if m.topic[3] ~= 'status' then msg2 = m; break end
    end
    luaunit.assertNil(msg2, 'second publish should be suppressed by DiffTrigger')

    stop_scope(svc_scope)
    clock:restore()
end

-- DeltaValue transforms a cumulative counter into a per-period delta.
function TestMetricsService:test_delta_value_pipeline()
    local clock = new_test_clock()
    local root      = fibers.current_scope()
    local bus       = make_bus()
    local test_conn = bus:connect()

    test_conn:retain({ 'cap', 'fs', 'configs', 'state' }, 'added')
    start_mock_hal(test_conn, root)

    local result_sub = test_conn:subscribe(
        { 'svc', 'metrics', '#' },
        { queue_len = 10, full = 'drop_oldest' })

    test_conn:retain({ 'cfg', 'metrics' }, bus_pipeline_config('rx_bytes', 0.1, {
        { type = 'DeltaValue', initial_val = 0 },
    }))
    local svc_scope = start_metrics(bus, root)
    flush_ticks()

    -- First reading: 1000 bytes; delta from initial 0 = 1000.
    test_conn:publish(
        { 'obs', 'v1', 'network', 'metric', 'rx_bytes' },
        { value = 1000 })

    local msg1 = recv_timeout(clock, result_sub, 0.4)
    luaunit.assertNotNil(msg1, 'expected first delta publish')
    luaunit.assertEquals(msg1.payload.value, 1000)

    -- Second reading: 1500 bytes; delta from 1000 = 500.
    test_conn:publish(
        { 'obs', 'v1', 'network', 'metric', 'rx_bytes' },
        { value = 1500 })

    local msg2 = recv_timeout(clock, result_sub, 0.4)
    luaunit.assertNotNil(msg2, 'expected second delta publish')
    luaunit.assertEquals(msg2.payload.value, 500)

    stop_scope(svc_scope)
    clock:restore()
end

-- HTTP protocol pipelines should enqueue a well-formed Mainflux request.
function TestMetricsService:test_http_pipeline_enqueues_request_payload()
    local clock = new_test_clock()
    local root      = fibers.current_scope()
    local bus       = make_bus()
    local test_conn = bus:connect()

    test_conn:retain({ 'cap', 'fs', 'configs', 'state' }, 'added')
    start_mock_hal(test_conn, root)

    local captured = nil
    local original_http_mod = package.loaded['services.metrics.http']
    package.loaded['services.metrics.http'] = {
        start_http_publisher = function()
            return {
                put_op = function(_, data)
                    captured = data
                    return op.always(true)
                end,
            }
        end,
    }

    local svc_scope = nil
    local st, _, test_err = fibers.run_scope(function()
        test_conn:retain({ 'cfg', 'metrics' }, {
            publish_period = 0.1,
            cloud_url = 'http://localhost:18080',
            pipelines = {
                sim = {
                    protocol = 'http',
                    process  = {},
                },
            },
        })

        svc_scope = start_metrics(bus, root)
        flush_ticks()

        test_conn:publish(
            { 'obs', 'v1', 'modem', 'metric', 'sim' },
            { value = 'present', namespace = { 'modem', 1, 'sim' } })

        clock:advance(0.3)
        time_harness.flush_ticks(20)

        luaunit.assertNotNil(captured, 'expected HTTP payload to be enqueued')
        luaunit.assertEquals(captured.uri,
            'http://localhost:18080/http/channels/ch-data/messages')
        luaunit.assertEquals(captured.auth, 'Thing test-thing-key')
        luaunit.assertNotNil(captured.body)

        local recs, decode_err = json.decode(captured.body)
        luaunit.assertNil(decode_err)
        luaunit.assertEquals(type(recs), 'table')
        luaunit.assertEquals(#recs, 1)
        luaunit.assertEquals(recs[1].n, 'modem.1.sim')
        luaunit.assertEquals(recs[1].vs, 'present')
    end)

    if svc_scope then
        stop_scope(svc_scope)
    end
    package.loaded['services.metrics.http'] = original_http_mod
    clock:restore()

    if st ~= 'ok' then
        error(test_err or ('metrics http scope failed: ' .. tostring(st)))
    end
end

-- Receiving a new config replaces pipelines; old metric names are dropped.
function TestMetricsService:test_config_update_replaces_pipelines()
    local clock = new_test_clock()
    local root      = fibers.current_scope()
    local bus       = make_bus()
    local test_conn = bus:connect()

    test_conn:retain({ 'cap', 'fs', 'configs', 'state' }, 'added')
    start_mock_hal(test_conn, root)

    local result_sub = test_conn:subscribe(
        { 'svc', 'metrics', '#' },
        { queue_len = 20, full = 'drop_oldest' }
    )

    -- Initial config: pipeline for 'sim'.
    test_conn:retain({ 'cfg', 'metrics' }, bus_pipeline_config('sim', 0.1))
    local svc_scope = start_metrics(bus, root)
    flush_ticks()

    -- Confirm 'sim' publishes under the initial config.
    test_conn:publish(
        { 'obs', 'v1', 'modem', 'metric', 'sim' },
        { value = 'present' }
    )
    local msg1 = recv_timeout(clock, result_sub, 0.4)
    luaunit.assertNotNil(msg1, 'expected sim metric before config update')

    -- Update config: replace 'sim' pipeline with 'rx_bytes'.
    test_conn:retain({ 'cfg', 'metrics' }, bus_pipeline_config('rx_bytes', 0.1))
    flush_ticks()

    -- 'rx_bytes' must publish after the config update.
    test_conn:publish(
        { 'obs', 'v1', 'network', 'metric', 'rx_bytes' },
        { value = 42 }
    )
    local msg2 = recv_timeout(clock, result_sub, 0.4)
    luaunit.assertNotNil(msg2, 'expected rx_bytes metric after config update')
    luaunit.assertEquals(msg2.payload.value, 42)

    stop_scope(svc_scope)
    clock:restore()
end

-- Two endpoints sharing the same pipeline name maintain isolated processing
-- state (DeltaValue counters don't bleed across endpoints).
function TestMetricsService:test_per_endpoint_state_isolation()
    local clock = new_test_clock()
    local root      = fibers.current_scope()
    local bus       = make_bus()
    local test_conn = bus:connect()

    test_conn:retain({ 'cap', 'fs', 'configs', 'state' }, 'added')
    start_mock_hal(test_conn, root)

    local result_sub = test_conn:subscribe(
        { 'svc', 'metrics', '#' },
        { queue_len = 20, full = 'drop_oldest' })

    test_conn:retain({ 'cfg', 'metrics' }, bus_pipeline_config('rx_bytes', 0.1, {
        { type = 'DeltaValue', initial_val = 0 },
    }))
    local svc_scope = start_metrics(bus, root)
    flush_ticks()

    -- WAN endpoint: 500 bytes → delta = 500.
    test_conn:publish(
        { 'obs', 'v1', 'network', 'metric', 'rx_bytes' },
        { value = 500, namespace = { 'wan', 'rx_bytes' } })

    -- LAN endpoint: 200 bytes → delta = 200 (independent state).
    test_conn:publish(
        { 'obs', 'v1', 'network', 'metric', 'rx_bytes' },
        { value = 200, namespace = { 'lan', 'rx_bytes' } })

    -- Collect both publishes within one tick window.
    local received = {}
    for _ = 1, 2 do
        local msg = recv_timeout(clock, result_sub, 0.4)
        if msg then
            local key = table.concat(msg.topic, '.')
            received[key] = msg.payload.value
        end
    end

    luaunit.assertEquals(received['svc.metrics.wan.rx_bytes'], 500)
    luaunit.assertEquals(received['svc.metrics.lan.rx_bytes'], 200)

    stop_scope(svc_scope)
    clock:restore()
end

-------------------------------------------------------------------------------
-- Entry point
-------------------------------------------------------------------------------

if is_entry_point then
    fibers.run(function()
        os.exit(luaunit.LuaUnit.run())
    end)
end
