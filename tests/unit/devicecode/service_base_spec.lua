local busmod    = require 'bus'
local fibers    = require 'fibers'
local sleep_mod = require 'fibers.sleep'

local probe     = require 'tests.support.bus_probe'
local runfibers = require 'tests.support.run_fibers'

local service_base = require 'devicecode.service_base'

local T = {}

local function wait_payload(conn, topic, timeout)
	return probe.wait_payload(conn, topic, { timeout = timeout or 0.1 })
end

local function wait_until(fn, timeout, interval)
	return probe.wait_until(fn, {
		timeout = timeout or 1.0,
		interval = interval or 0.01,
	})
end

local function topic_equal(a, b)
	if type(a) ~= 'table' or type(b) ~= 'table' or #a ~= #b then
		return false
	end
	for i = 1, #a do
		if a[i] ~= b[i] then return false end
	end
	return true
end

function T.service_base_status_preserves_legacy_shape()
	runfibers.run(function()
		local bus    = busmod.new()
		local conn   = bus:connect()
		local reader = bus:connect()

		local svc = service_base.new(conn, { name = 'demo', env = 'test' })
		svc:status('running', { note = 'legacy-path' })

		local payload = wait_payload(reader, { 'svc', 'demo', 'status' }, 0.2)
		assert(type(payload) == 'table')
		assert(payload.state == 'running')
		assert(payload.note == 'legacy-path')
		assert(type(payload.ts) == 'number')
		assert(type(payload.at) == 'string')

		-- Legacy status() must not force the new lifecycle fields.
		assert(payload.ready == nil)
		assert(payload.run_id == nil)

		local obs = wait_payload(reader, { 'obs', 'state', 'demo', 'status' }, 0.2)
		assert(type(obs) == 'table')
		assert(obs.state == 'running')
		assert(obs.note == 'legacy-path')
	end, { timeout = 2.0 })
end

function T.service_base_announce_publishes_retained_metadata()
	runfibers.run(function()
		local bus    = busmod.new()
		local conn   = bus:connect()
		local reader = bus:connect()

		local svc = service_base.new(conn, { name = 'demo', env = 'test' })
		local ann = svc:announce({
			kind = 'example',
			schema = 'devicecode.service/demo/1',
		})

		assert(type(ann) == 'table')
		assert(ann.name == 'demo')
		assert(ann.env == 'test')
		assert(ann.kind == 'example')
		assert(ann.schema == 'devicecode.service/demo/1')
		assert(type(ann.run_id) == 'string')

		local payload = wait_payload(reader, { 'svc', 'demo', 'announce' }, 0.2)
		assert(type(payload) == 'table')
		assert(payload.name == 'demo')
		assert(payload.env == 'test')
		assert(payload.kind == 'example')
		assert(payload.schema == 'devicecode.service/demo/1')
		assert(type(payload.run_id) == 'string')
	end, { timeout = 2.0 })
end

function T.service_base_lifecycle_helpers_publish_ready_and_run_id()
	runfibers.run(function()
		local bus    = busmod.new()
		local conn   = bus:connect()
		local reader = bus:connect()

		local svc = service_base.new(conn, { name = 'demo', env = 'test' })

		local p1 = svc:starting({ boot = 'phase-1' })
		assert(type(p1) == 'table')
		assert(p1.state == 'starting')
		assert(p1.ready == false)
		assert(type(p1.run_id) == 'string')

		local s1 = wait_payload(reader, { 'svc', 'demo', 'status' }, 0.2)
		assert(type(s1) == 'table')
		assert(s1.state == 'starting')
		assert(s1.ready == false)
		assert(s1.boot == 'phase-1')
		assert(type(s1.run_id) == 'string')

		local run_id = s1.run_id

		local p2 = svc:running({ phase = 'bootstrap' })
		assert(p2.state == 'running')
		assert(p2.ready == false)
		assert(p2.run_id == run_id)

		local s2 = wait_payload(reader, { 'svc', 'demo', 'status' }, 0.2)
		assert(type(s2) == 'table')
		assert(s2.state == 'running')
		assert(s2.ready == false)
		assert(s2.phase == 'bootstrap')
		assert(s2.run_id == run_id)

		local p3 = svc:set_ready(true, { endpoint_bound = true })
		assert(p3.state == 'running')
		assert(p3.ready == true)
		assert(p3.endpoint_bound == true)
		assert(p3.run_id == run_id)

		local s3 = wait_payload(reader, { 'svc', 'demo', 'status' }, 0.2)
		assert(type(s3) == 'table')
		assert(s3.state == 'running')
		assert(s3.ready == true)
		assert(s3.endpoint_bound == true)
		assert(s3.run_id == run_id)

		local p4 = svc:degraded({ ready = true, reason = 'link_lost' })
		assert(p4.state == 'degraded')
		assert(p4.ready == true)
		assert(p4.reason == 'link_lost')
		assert(p4.run_id == run_id)

		local s4 = wait_payload(reader, { 'svc', 'demo', 'status' }, 0.2)
		assert(type(s4) == 'table')
		assert(s4.state == 'degraded')
		assert(s4.ready == true)
		assert(s4.reason == 'link_lost')
		assert(s4.run_id == run_id)

		local p5 = svc:failed('boom')
		assert(p5.state == 'failed')
		assert(p5.ready == false)
		assert(p5.reason == 'boom')
		assert(p5.run_id == run_id)

		local s5 = wait_payload(reader, { 'svc', 'demo', 'status' }, 0.2)
		assert(type(s5) == 'table')
		assert(s5.state == 'failed')
		assert(s5.ready == false)
		assert(s5.reason == 'boom')
		assert(s5.run_id == run_id)
	end, { timeout = 2.0 })
end

function T.service_base_run_id_is_stable_within_one_instance_and_changes_across_instances()
	runfibers.run(function()
		local bus  = busmod.new()
		local conn = bus:connect()

		local svc1 = service_base.new(conn, { name = 'demo-a', env = 'test' })
		local a1 = svc1:starting()
		local a2 = svc1:running()
		local a3 = svc1:set_ready(true)

		assert(type(a1.run_id) == 'string')
		assert(a1.run_id == a2.run_id)
		assert(a2.run_id == a3.run_id)

		local svc2 = service_base.new(conn, { name = 'demo-b', env = 'test' })
		local b1 = svc2:starting()

		assert(type(b1.run_id) == 'string')
		assert(b1.run_id ~= a1.run_id)
	end, { timeout = 2.0 })
end

function T.service_base_scope_exit_unretains_status_and_announce()
	runfibers.run(function()
		local bus    = busmod.new()
		local reader = bus:connect()

		local watch = reader:watch_retained({ 'svc', 'demo', '#' }, {
			replay = true,
			queue_len = 16,
			full = 'drop_oldest',
		})

		local saw_status_retain = false
		local saw_announce_retain = false
		local saw_status_unretain = false
		local saw_announce_unretain = false

		local st, rep = fibers.run_scope(function()
			local conn = bus:connect()
			local svc = service_base.new(conn, { name = 'demo', env = 'test' })
			svc:announce({ kind = 'example' })
			svc:running()
			svc:set_ready(true)

			assert(wait_until(function()
				local ev, err = watch:recv()
				if not ev then return false end

				if ev.op == 'retain' then
					if topic_equal(ev.topic, { 'svc', 'demo', 'announce' }) then
						saw_announce_retain = true
					elseif topic_equal(ev.topic, { 'svc', 'demo', 'status' }) then
						saw_status_retain = true
					end
				end

				return saw_status_retain and saw_announce_retain
			end, 1.0, 0.01))
		end)

		assert(st == 'ok', tostring(st))
		assert(type(rep) == 'table')

		assert(wait_until(function()
			local ev, err = watch:recv()
			if not ev then return false end

			if ev.op == 'unretain' then
				if topic_equal(ev.topic, { 'svc', 'demo', 'status' }) then
					saw_status_unretain = true
				elseif topic_equal(ev.topic, { 'svc', 'demo', 'announce' }) then
					saw_announce_unretain = true
				end
			end

			return saw_status_unretain and saw_announce_unretain
		end, 1.0, 0.01))

		watch:unwatch()
	end, { timeout = 2.0 })
end

function T.service_base_wait_service_ready_returns_on_ready_true()
	runfibers.run(function(scope)
		local bus      = busmod.new()
		local waiter_c = bus:connect()
		local pub_c    = bus:connect()

		local waiter = service_base.new(waiter_c, { name = 'waiter', env = 'test' })

		local got
		local ok, err = scope:spawn(function()
			got = assert(waiter:wait_service_ready('dep', { timeout = 1.0 }))
		end)
		assert(ok, tostring(err))

		sleep_mod.sleep(0.02)
		pub_c:retain({ 'svc', 'dep', 'status' }, { state = 'running', ready = false })
		sleep_mod.sleep(0.02)
		pub_c:retain({ 'svc', 'dep', 'status' }, { state = 'running', ready = true, run_id = 'dep-run-1' })

		assert(wait_until(function()
			return type(got) == 'table' and got.ready == true and got.run_id == 'dep-run-1'
		end, 1.0, 0.01))
	end, { timeout = 2.0 })
end

function T.service_base_wait_service_ready_supports_legacy_running_mode()
	runfibers.run(function(scope)
		local bus      = busmod.new()
		local waiter_c = bus:connect()
		local pub_c    = bus:connect()

		local waiter = service_base.new(waiter_c, { name = 'waiter', env = 'test' })

		local got
		local ok, err = scope:spawn(function()
			got = assert(waiter:wait_service_ready('dep', {
				timeout = 1.0,
				accept_running_without_ready = true,
			}))
		end)
		assert(ok, tostring(err))

		sleep_mod.sleep(0.02)
		pub_c:retain({ 'svc', 'dep', 'status' }, { state = 'running' })

		assert(wait_until(function()
			return type(got) == 'table' and got.state == 'running'
		end, 1.0, 0.01))
	end, { timeout = 2.0 })
end

function T.service_base_wait_service_ready_times_out_when_not_ready()
	runfibers.run(function()
		local bus      = busmod.new()
		local waiter_c = bus:connect()

		local waiter = service_base.new(waiter_c, { name = 'waiter', env = 'test' })
		local payload, err = waiter:wait_service_ready('missing', { timeout = 0.05 })

		assert(payload == nil)
		assert(err == 'timeout')
	end, { timeout = 2.0 })
end

function T.service_base_topic_helpers_build_canonical_topics()
	runfibers.run(function()
		local bus  = busmod.new()
		local conn = bus:connect()

		local svc = service_base.new(conn, { name = 'demo', env = 'test' })

		assert(topic_equal(svc:service_topic('status'), { 'svc', 'demo', 'status' }))
		assert(topic_equal(svc:status_topic(), { 'svc', 'demo', 'status' }))
		assert(topic_equal(svc:announce_topic(), { 'svc', 'demo', 'announce' }))
	end, { timeout = 2.0 })
end

return T
