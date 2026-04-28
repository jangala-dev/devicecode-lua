local busmod        = require 'bus'
local fibers        = require 'fibers'
local sleep         = require 'fibers.sleep'
local op            = require 'fibers.op'

local runfibers     = require 'tests.support.run_fibers'
local probe         = require 'tests.support.bus_probe'
local service_base  = require 'devicecode.service_base'

local T = {}

local function wait_payload(conn, topic, timeout)
	return probe.wait_payload(conn, topic, { timeout = timeout or 0.5 })
end

local function expect_no_message(conn, topic, timeout)
	timeout = timeout or 0.05
	local sub = conn:subscribe(topic)

	local which = fibers.perform(op.named_choice{
		msg     = sub:recv_op():wrap(function() return 'msg' end),
		timeout = sleep.sleep_op(timeout):wrap(function() return 'timeout' end),
	})

	sub:unsubscribe()
	assert(which == 'timeout', 'unexpected retained/publication on ' .. table.concat(topic, '/'))
end

function T.new_service_publishes_meta_announce_and_status()
	runfibers.run(function()
		local bus    = busmod.new()
		local conn   = bus:connect()
		local reader = bus:connect()

		local svc = service_base.new(conn, {
			name = 'alpha',
			env  = 'test',
			meta = { role = 'worker' },
			announce = { boot = 'cold' },
		})

		local meta = wait_payload(reader, { 'svc', 'alpha', 'meta' }, 0.5)
		assert(meta.service == 'alpha')
		assert(meta.env == 'test')
		assert(meta.role == 'worker')
		assert(type(meta.run_id) == 'string' and meta.run_id ~= '')

		local ann = wait_payload(reader, { 'svc', 'alpha', 'announce' }, 0.5)
		assert(ann.service == 'alpha')
		assert(ann.boot == 'cold')
		assert(ann.run_id == meta.run_id)

		local status_payload = svc:running({ phase = 'steady' })
		assert(status_payload.state == 'running')
		assert(status_payload.phase == 'steady')
		assert(status_payload.run_id == meta.run_id)

		local status = wait_payload(reader, { 'svc', 'alpha', 'status' }, 0.5)
		assert(status.state == 'running')
		assert(status.phase == 'steady')
		assert(status.run_id == meta.run_id)
	end)
end

function T.obs_helpers_publish_legacy_and_v1_topics()
	runfibers.run(function()
		local bus    = busmod.new()
		local conn   = bus:connect()
		local reader = bus:connect()

		local svc = service_base.new(conn, { name = 'beta', env = 'test' })

		-- Subscribe BEFORE publishing non-retained events/logs.
        local evt_legacy_sub = reader:subscribe({ 'obs', 'event', 'beta', 'tick' })
        local evt_v1_sub     = reader:subscribe({ 'obs', 'v1', 'beta', 'event', 'tick' })

        local log_legacy_sub = reader:subscribe({ 'obs', 'log', 'beta', 'info' })
        local log_v1_sub     = reader:subscribe({ 'obs', 'v1', 'beta', 'event', 'log' })

        local counter_v1_sub = reader:subscribe({ 'obs', 'v1', 'beta', 'counter', 'restarts' })

		svc:obs_event('tick', { n = 1 })
		svc:obs_state('phase', { value = 'booting' })
		svc:obs_log('info', { message = 'hello' })
		svc:obs_metric('temperature', { c = 42 })
		svc:obs_counter('restarts', { n = 3 })

		local evt_legacy, err = evt_legacy_sub:recv()
		assert(evt_legacy, tostring(err))
		assert(type(evt_legacy.payload) == 'table')
		assert(evt_legacy.payload.n == 1)

		local evt_v1, err2 = evt_v1_sub:recv()
		assert(evt_v1, tostring(err2))
		assert(type(evt_v1.payload) == 'table')
		assert(evt_v1.payload.n == 1)

		local state_legacy = wait_payload(reader, { 'obs', 'state', 'beta', 'phase' }, 0.2)
		assert(type(state_legacy) == 'table')
		assert(state_legacy.value == 'booting')

		local state_v1 = wait_payload(reader, { 'obs', 'v1', 'beta', 'metric', 'phase' }, 0.2)
		assert(type(state_v1) == 'table')
		assert(state_v1.value == 'booting')

		local log_legacy, err3 = log_legacy_sub:recv()
		assert(log_legacy, tostring(err3))
		assert(type(log_legacy.payload) == 'table')
		assert(log_legacy.payload.message == 'hello')

		local log_v1, err4 = log_v1_sub:recv()
		assert(log_v1, tostring(err4))
		assert(type(log_v1.payload) == 'table')
		assert(log_v1.payload.message == 'hello')
		assert(log_v1.payload.level == 'info')

		local metric_v1 = wait_payload(reader, { 'obs', 'v1', 'beta', 'metric', 'temperature' }, 0.2)
		assert(type(metric_v1) == 'table')
		assert(metric_v1.c == 42)

        local counter_v1, err5 = counter_v1_sub:recv()
        assert(counter_v1, tostring(err5))
        assert(counter_v1.payload.n == 3)

		evt_legacy_sub:unsubscribe()
		evt_v1_sub:unsubscribe()
		log_legacy_sub:unsubscribe()
		log_v1_sub:unsubscribe()
        counter_v1_sub:unsubscribe()
	end)
end

function T.scope_exit_unretains_tracked_topics()
	runfibers.run(function(scope)
		local bus    = busmod.new()
		local reader = bus:connect()

		local child, child_err = scope:child()
		assert(child, tostring(child_err))

		local ok, err = child:spawn(function()
			local svc = service_base.new(bus:connect(), {
				name = 'gamma',
				env  = 'test',
				meta = { role = 'ephemeral' },
				announce = { mode = 'test' },
			})
			svc:ready({ detail = 'complete' })
			svc:obs_metric('phase', { value = 'ready' })
		end)
		assert(ok, tostring(err))

		local st = fibers.perform(child:join_op())
		assert(st == 'ok' or st == 'cancelled' or st == 'failed')

		expect_no_message(reader, { 'svc', 'gamma', 'meta' }, 0.05)
		expect_no_message(reader, { 'svc', 'gamma', 'announce' }, 0.05)
		expect_no_message(reader, { 'svc', 'gamma', 'status' }, 0.05)
		expect_no_message(reader, { 'obs', 'state', 'gamma', 'status' }, 0.05)
		expect_no_message(reader, { 'obs', 'v1', 'gamma', 'metric', 'status' }, 0.05)
		expect_no_message(reader, { 'obs', 'v1', 'gamma', 'metric', 'phase' }, 0.05)
	end)
end

function T.wait_service_ready_returns_on_explicit_ready()
	runfibers.run(function(scope)
		local bus   = busmod.new()
		local admin = bus:connect()

		local ok, err = scope:spawn(function()
			sleep.sleep(0.01)
			admin:retain({ 'svc', 'delta', 'status' }, {
				state = 'starting',
				ts = 1,
				at = 't1',
			})
			sleep.sleep(0.01)
			admin:retain({ 'svc', 'delta', 'status' }, {
				state = 'running',
				ready = true,
				ts = 2,
				at = 't2',
			})
		end)
		assert(ok, tostring(err))

		local payload, wait_err = service_base.wait_service_ready(bus:connect(), 'delta', {
			timeout = 0.5,
		})
		assert(payload, tostring(wait_err))
		assert(payload.state == 'running')
		assert(payload.ready == true)
	end)
end

function T.wait_service_ready_accepts_running_without_ready_when_requested()
	runfibers.run(function(scope)
		local bus   = busmod.new()
		local admin = bus:connect()

		local ok, err = scope:spawn(function()
			sleep.sleep(0.01)
			admin:retain({ 'svc', 'zeta', 'status' }, {
				state = 'starting',
				ts = 1,
				at = 't1',
			})
			sleep.sleep(0.01)
			admin:retain({ 'svc', 'zeta', 'status' }, {
				state = 'running',
				ts = 2,
				at = 't2',
			})
		end)
		assert(ok, tostring(err))

		local payload, wait_err = service_base.wait_service_ready(bus:connect(), 'zeta', {
			timeout = 0.5,
			accept_running_without_ready = true,
		})
		assert(payload, tostring(wait_err))
		assert(payload.state == 'running')
		assert(payload.ready == nil)
	end)
end

function T.wait_service_ready_times_out_cleanly()
	runfibers.run(function()
		local bus = busmod.new()

		local payload, err = service_base.wait_service_ready(bus:connect(), 'epsilon', {
			timeout = 0.05,
		})
		assert(payload == nil)
		assert(err == 'timeout')
	end)
end

return T
