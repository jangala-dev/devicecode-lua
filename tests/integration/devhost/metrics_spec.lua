-- tests/integration/metrics/service_spec.lua
--
-- Service-level integration tests for the metrics service.
-- Each test spins up the full metrics service in a child fiber scope,
-- interacts with it via bus messages, and asserts on the output.
--
-- Virtual time is installed inside each runfibers.run callback so that the
-- real-clock timeout guard in run_fibers.lua still functions correctly.

local fibers       = require 'fibers'
local perform      = fibers.perform
local op           = require 'fibers.op'
local busmod       = require 'bus'
local json         = require 'cjson.safe'
local virtual_time = require 'tests.support.virtual_time'
local time_harness = require 'tests.support.time_harness'
local runfibers    = require 'tests.support.run_fibers'

-------------------------------------------------------------------------------
-- Module-level constants
-------------------------------------------------------------------------------

-- Sample mainflux.cfg the mock HAL returns for every read request.
local MAINFLUX_CFG = json.encode({
	thing_key = 'test-thing-key',
	channels  = {
		{ id = 'ch-data',    name = 'test_data',    metadata = { channel_type = 'data' } },
		{ id = 'ch-control', name = 'test_control', metadata = { channel_type = 'control' } },
	},
})

-------------------------------------------------------------------------------
-- Helpers (shared across all tests in this file)
-------------------------------------------------------------------------------

local function make_bus()
	return busmod.new({ q_length = 100, s_wild = '+', m_wild = '#' })
end

local function new_test_clock()
	return virtual_time.install({ monotonic = 0, realtime = 1700000000 })
end

local function flush_ticks(max_ticks)
	time_harness.flush_ticks(max_ticks or 20)
end

-- Subscribe to svc/metrics/# and wait for the next non-status message,
-- advancing the virtual clock in steps until one arrives or timeout lapses.
local function recv_metric(clock, sub, timeout_s)
	local step     = 0.05
	local max_ticks = 20
	local elapsed  = 0
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

-- Drain all currently-available non-status messages without advancing time.
local function drain_non_status(sub, max_ticks)
	max_ticks = max_ticks or 20
	local messages = {}
	for tick = 1, max_ticks do
		local saw_any = false
		while true do
			local ok, msg = time_harness.try_op_now(function() return sub:recv_op() end)
			if not ok then break end
			saw_any = true
			if msg.topic[3] ~= 'status' then
				messages[#messages + 1] = msg
			end
		end
		if not saw_any or tick == max_ticks then break end
		time_harness.flush_ticks(1)
	end
	return messages
end

-- Bind cap/fs/configs/rpc/read and respond with MAINFLUX_CFG forever.
-- The metrics service uses the plural 'configs' path which fake_hal does not cover.
local function start_mock_hal(conn, root_scope)
	local ep = conn:bind(
		{ 'cap', 'fs', 'configs', 'rpc', 'read' },
		{ queue_len = 5 })

	root_scope:spawn(function()
		while true do
			local req, _ = perform(ep:recv_op())
			if not req then break end
			req:reply({ ok = true, reason = MAINFLUX_CFG })
		end
	end)
end

-- Start the metrics service in a fresh child scope.
-- Clears package.loaded so each test gets a clean module-level State.
local function start_metrics(bus, root_scope, opts)
	local svc_scope = root_scope:child()
	svc_scope:spawn(function()
		package.loaded['services.metrics'] = nil
		local metrics  = require 'services.metrics'
		local svc_conn = bus:connect()
		metrics.start(svc_conn, opts or { name = 'metrics' })
	end)
	return svc_scope
end

local function stop_scope(svc_scope)
	svc_scope:cancel('test done')
	perform(svc_scope:join_op())
end

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

-------------------------------------------------------------------------------
-- Tests
-------------------------------------------------------------------------------

local T = {}

-- Publish a metric and verify the processed value is re-published on the bus.
function T.metric_published_via_bus()
	runfibers.run(function(scope)
		local clock     = new_test_clock()
		scope:finally(function() clock:restore() end)
		local bus       = make_bus()
		local test_conn = bus:connect()

		test_conn:retain({ 'cap', 'fs', 'configs', 'state' }, 'added')
		start_mock_hal(test_conn, scope)
		test_conn:retain({ 'svc', 'time', 'synced' }, true)

		local result_sub = test_conn:subscribe(
			{ 'svc', 'metrics', '#' },
			{ queue_len = 10, full = 'drop_oldest' })

		test_conn:retain({ 'cfg', 'metrics' }, bus_pipeline_config('sim', 0.1))

		local svc_scope = start_metrics(bus, scope)
		flush_ticks()

		test_conn:publish(
			{ 'obs', 'v1', 'modem', 'metric', 'sim' },
			{ value = 'present', namespace = { 'modem', 1, 'sim' } })

		local msg = recv_metric(clock, result_sub, 0.5)

		assert(msg ~= nil, 'expected bus publish of sim metric')
		assert(msg.payload.value == 'present',
			'expected value=present, got ' .. tostring(msg.payload.value))

		stop_scope(svc_scope)
		clock:restore()
	end, { timeout = 3.0 })
end

-- A namespace field in the payload overrides the output bus topic segments.
function T.namespace_overrides_topic_key()
	runfibers.run(function(scope)
		local clock     = new_test_clock()
		scope:finally(function() clock:restore() end)
		local bus       = make_bus()
		local test_conn = bus:connect()

		test_conn:retain({ 'cap', 'fs', 'configs', 'state' }, 'added')
		start_mock_hal(test_conn, scope)
		test_conn:retain({ 'svc', 'time', 'synced' }, true)

		local result_sub = test_conn:subscribe(
			{ 'svc', 'metrics', '#' },
			{ queue_len = 10, full = 'drop_oldest' })

		test_conn:retain({ 'cfg', 'metrics' }, bus_pipeline_config('rx_bytes', 0.1))
		local svc_scope = start_metrics(bus, scope)
		flush_ticks()

		test_conn:publish(
			{ 'obs', 'v1', 'network', 'metric', 'rx_bytes' },
			{ value = 1024, namespace = { 'wan', 'rx_bytes' } })

		local msg = recv_metric(clock, result_sub, 0.5)

		assert(msg ~= nil, 'expected bus publish with namespace key')
		assert(msg.topic[3] == 'wan',
			'expected topic[3]=wan, got ' .. tostring(msg.topic[3]))
		assert(msg.topic[4] == 'rx_bytes',
			'expected topic[4]=rx_bytes, got ' .. tostring(msg.topic[4]))
		assert(msg.payload.value == 1024,
			'expected value=1024, got ' .. tostring(msg.payload.value))

		stop_scope(svc_scope)
		clock:restore()
	end, { timeout = 3.0 })
end

-- A metric with no matching pipeline is silently dropped.
function T.unknown_metric_dropped()
	runfibers.run(function(scope)
		local clock     = new_test_clock()
		scope:finally(function() clock:restore() end)
		local bus       = make_bus()
		local test_conn = bus:connect()

		test_conn:retain({ 'cap', 'fs', 'configs', 'state' }, 'added')
		start_mock_hal(test_conn, scope)
		test_conn:retain({ 'svc', 'time', 'synced' }, true)

		local result_sub = test_conn:subscribe(
			{ 'svc', 'metrics', '#' },
			{ queue_len = 10, full = 'drop_oldest' })

		-- Config only knows about 'sim'; we will publish 'rx_bytes'.
		test_conn:retain({ 'cfg', 'metrics' }, bus_pipeline_config('sim', 0.1))
		local svc_scope = start_metrics(bus, scope)
		flush_ticks()

		test_conn:publish(
			{ 'obs', 'v1', 'network', 'metric', 'rx_bytes' },
			{ value = 9999 })

		clock:advance(0.25)
		time_harness.flush_ticks(20)
		local messages = drain_non_status(result_sub)

		assert(#messages == 0,
			'expected 0 messages for unknown metric, got ' .. tostring(#messages))

		stop_scope(svc_scope)
		clock:restore()
	end, { timeout = 3.0 })
end

-- DiffTrigger with any-change suppresses the second publish when value is unchanged.
function T.difftrigger_suppresses_unchanged_value()
	runfibers.run(function(scope)
		local clock     = new_test_clock()
		scope:finally(function() clock:restore() end)
		local bus       = make_bus()
		local test_conn = bus:connect()

		test_conn:retain({ 'cap', 'fs', 'configs', 'state' }, 'added')
		start_mock_hal(test_conn, scope)
		test_conn:retain({ 'svc', 'time', 'synced' }, true)

		local result_sub = test_conn:subscribe(
			{ 'svc', 'metrics', '#' },
			{ queue_len = 10, full = 'drop_oldest' })

		test_conn:retain({ 'cfg', 'metrics' }, bus_pipeline_config('sim', 0.1, {
			{ type = 'DiffTrigger', diff_method = 'any-change' },
		}))
		local svc_scope = start_metrics(bus, scope)
		flush_ticks()

		-- First publish: new value — should pass DiffTrigger.
		test_conn:publish(
			{ 'obs', 'v1', 'modem', 'metric', 'sim' },
			{ value = 'present' })

		local msg1 = recv_metric(clock, result_sub, 0.4)
		assert(msg1 ~= nil, 'expected first publish to pass DiffTrigger')
		assert(msg1.payload.value == 'present',
			'unexpected value: ' .. tostring(msg1.payload.value))

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
		assert(msg2 == nil, 'second publish should be suppressed by DiffTrigger')

		stop_scope(svc_scope)
		clock:restore()
	end, { timeout = 3.0 })
end

-- DeltaValue transforms a cumulative counter into a per-period delta.
function T.delta_value_pipeline()
	runfibers.run(function(scope)
		local clock     = new_test_clock()
		scope:finally(function() clock:restore() end)
		local bus       = make_bus()
		local test_conn = bus:connect()

		test_conn:retain({ 'cap', 'fs', 'configs', 'state' }, 'added')
		start_mock_hal(test_conn, scope)
		test_conn:retain({ 'svc', 'time', 'synced' }, true)

		local result_sub = test_conn:subscribe(
			{ 'svc', 'metrics', '#' },
			{ queue_len = 10, full = 'drop_oldest' })

		test_conn:retain({ 'cfg', 'metrics' }, bus_pipeline_config('rx_bytes', 0.1, {
			{ type = 'DeltaValue', initial_val = 0 },
		}))
		local svc_scope = start_metrics(bus, scope)
		flush_ticks()

		-- First reading: 1000 bytes; delta from initial 0 = 1000.
		test_conn:publish(
			{ 'obs', 'v1', 'network', 'metric', 'rx_bytes' },
			{ value = 1000 })

		local msg1 = recv_metric(clock, result_sub, 0.4)
		assert(msg1 ~= nil, 'expected first delta publish')
		assert(msg1.payload.value == 1000,
			'expected delta=1000, got ' .. tostring(msg1.payload.value))

		-- Second reading: 1500 bytes; delta from 1000 = 500.
		test_conn:publish(
			{ 'obs', 'v1', 'network', 'metric', 'rx_bytes' },
			{ value = 1500 })

		local msg2 = recv_metric(clock, result_sub, 0.4)
		assert(msg2 ~= nil, 'expected second delta publish')
		assert(msg2.payload.value == 500,
			'expected delta=500, got ' .. tostring(msg2.payload.value))

		stop_scope(svc_scope)
		clock:restore()
	end, { timeout = 3.0 })
end

-- HTTP pipelines should enqueue a well-formed Mainflux request payload.
function T.http_pipeline_enqueues_request_payload()
	-- Save originals so we can restore after the test.
	local original_http_mod = package.loaded['services.metrics.http']

	local captured = nil

	-- Stub the HTTP publisher so we can inspect what gets enqueued.
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

	local ok_run, run_err = pcall(function()
		runfibers.run(function(scope)
			local clock     = new_test_clock()
			scope:finally(function() clock:restore() end)
			local bus       = make_bus()
			local test_conn = bus:connect()

			test_conn:retain({ 'cap', 'fs', 'configs', 'state' }, 'added')
			start_mock_hal(test_conn, scope)
			test_conn:retain({ 'svc', 'time', 'synced' }, true)

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

			local svc_scope = start_metrics(bus, scope)
			flush_ticks()

			test_conn:publish(
				{ 'obs', 'v1', 'modem', 'metric', 'sim' },
				{ value = 'present', namespace = { 'modem', 1, 'sim' } })

			clock:advance(0.3)
			time_harness.flush_ticks(20)

			assert(captured ~= nil, 'expected HTTP payload to be enqueued')
			assert(captured.uri == 'http://localhost:18080/http/channels/ch-data/messages',
				'unexpected uri: ' .. tostring(captured.uri))
			assert(captured.auth == 'Thing test-thing-key',
				'unexpected auth: ' .. tostring(captured.auth))
			assert(captured.body ~= nil, 'expected non-nil body')

			local recs, decode_err = json.decode(captured.body)
			assert(decode_err == nil, 'JSON decode error: ' .. tostring(decode_err))
			assert(type(recs) == 'table', 'expected table of records')
			assert(#recs == 1, 'expected 1 record, got ' .. tostring(#recs))
			assert(recs[1].n == 'modem.1.sim',
				'expected n=modem.1.sim, got ' .. tostring(recs[1].n))
			assert(recs[1].vs == 'present',
				'expected vs=present, got ' .. tostring(recs[1].vs))

			stop_scope(svc_scope)
			clock:restore()
		end, { timeout = 3.0 })
	end)

	-- Always restore the stub.
	package.loaded['services.metrics.http'] = original_http_mod

	assert(ok_run, tostring(run_err))
end

-- Receiving a new config replaces existing pipelines; old metric names are dropped.
function T.config_update_replaces_pipelines()
	runfibers.run(function(scope)
		local clock     = new_test_clock()
		scope:finally(function() clock:restore() end)
		local bus       = make_bus()
		local test_conn = bus:connect()

		test_conn:retain({ 'cap', 'fs', 'configs', 'state' }, 'added')
		start_mock_hal(test_conn, scope)
		test_conn:retain({ 'svc', 'time', 'synced' }, true)

		local result_sub = test_conn:subscribe(
			{ 'svc', 'metrics', '#' },
			{ queue_len = 20, full = 'drop_oldest' })

		-- Initial config: pipeline for 'sim'.
		test_conn:retain({ 'cfg', 'metrics' }, bus_pipeline_config('sim', 0.1))
		local svc_scope = start_metrics(bus, scope)
		flush_ticks()

		-- Confirm 'sim' publishes under the initial config.
		test_conn:publish(
			{ 'obs', 'v1', 'modem', 'metric', 'sim' },
			{ value = 'present' })

		local msg1 = recv_metric(clock, result_sub, 0.4)
		assert(msg1 ~= nil, 'expected sim metric before config update')

		-- Update config: replace 'sim' pipeline with 'rx_bytes'.
		test_conn:retain({ 'cfg', 'metrics' }, bus_pipeline_config('rx_bytes', 0.1))
		flush_ticks()

		-- 'rx_bytes' must publish after the config update.
		test_conn:publish(
			{ 'obs', 'v1', 'network', 'metric', 'rx_bytes' },
			{ value = 42 })

		local msg2 = recv_metric(clock, result_sub, 0.4)
		assert(msg2 ~= nil, 'expected rx_bytes metric after config update')
		assert(msg2.payload.value == 42,
			'expected value=42, got ' .. tostring(msg2.payload.value))

		stop_scope(svc_scope)
		clock:restore()
	end, { timeout = 3.0 })
end

-- Two endpoints sharing the same pipeline name maintain isolated processing state.
function T.per_endpoint_state_isolation()
	runfibers.run(function(scope)
		local clock     = new_test_clock()
		scope:finally(function() clock:restore() end)
		local bus       = make_bus()
		local test_conn = bus:connect()

		test_conn:retain({ 'cap', 'fs', 'configs', 'state' }, 'added')
		start_mock_hal(test_conn, scope)
		test_conn:retain({ 'svc', 'time', 'synced' }, true)

		local result_sub = test_conn:subscribe(
			{ 'svc', 'metrics', '#' },
			{ queue_len = 20, full = 'drop_oldest' })

		test_conn:retain({ 'cfg', 'metrics' }, bus_pipeline_config('rx_bytes', 0.1, {
			{ type = 'DeltaValue', initial_val = 0 },
		}))
		local svc_scope = start_metrics(bus, scope)
		flush_ticks()

		-- WAN endpoint: 500 bytes → delta = 500 (from initial 0).
		test_conn:publish(
			{ 'obs', 'v1', 'network', 'metric', 'rx_bytes' },
			{ value = 500, namespace = { 'wan', 'rx_bytes' } })

		-- LAN endpoint: 200 bytes → delta = 200 (independent state from WAN).
		test_conn:publish(
			{ 'obs', 'v1', 'network', 'metric', 'rx_bytes' },
			{ value = 200, namespace = { 'lan', 'rx_bytes' } })

		-- Collect both publishes within one tick window.
		local received = {}
		for _ = 1, 2 do
			local msg = recv_metric(clock, result_sub, 0.4)
			if msg then
				local key = table.concat(msg.topic, '.')
				received[key] = msg.payload.value
			end
		end

		assert(received['svc.metrics.wan.rx_bytes'] == 500,
			'expected wan delta=500, got ' .. tostring(received['svc.metrics.wan.rx_bytes']))
		assert(received['svc.metrics.lan.rx_bytes'] == 200,
			'expected lan delta=200, got ' .. tostring(received['svc.metrics.lan.rx_bytes']))

		stop_scope(svc_scope)
		clock:restore()
	end, { timeout = 3.0 })
end

return T
