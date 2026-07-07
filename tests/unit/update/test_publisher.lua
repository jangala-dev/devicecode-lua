-- tests/unit/update/test_publisher.lua

local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'
local busmod = require 'bus'

local model_mod = require 'services.update.model'
local publisher = require 'services.update.publisher'
local topics = require 'services.update.topics'
local probe = require 'tests.support.bus_probe'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a, b, msg) if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end end
local function assert_true(v, msg) if v ~= true then fail(msg or ('expected true, got ' .. tostring(v))) end end
local function assert_not_nil(v, msg) if v == nil then fail(msg or 'expected non-nil value') end end

function tests.test_publisher_retains_initial_and_changed_state()
	fibers.run(function (scope)
		local bus = busmod.new()
		local conn = bus:connect()
		local view_conn = bus:connect()
		local m = model_mod.new(model_mod.service_initial('update', 0))

		local pub, err = publisher.start(scope, { conn = conn, model = m })
		assert_not_nil(pub, err)

		local view = view_conn:retained_view(topics.update_summary())
		local payload = probe.wait_retained_payload(view_conn, topics.update_summary(), { timeout = 0.2, view = view })
		assert_eq(payload.service, 'update')
		assert_eq(payload.state, 'starting')

		m:update(function (s)
			s.state = 'running'
			s.ready = true
			return s
		end)

		local ok_update = probe.wait_until(function ()
			local msg = view:get(topics.update_summary())
			return msg and msg.payload and msg.payload.state == 'running'
		end, { timeout = 0.3 })

		assert_true(ok_update, 'expected retained update')
		local updated = view:get(topics.update_summary()).payload
		assert_eq(updated.ready, true)
		view:close()

		pub:stop('test complete')
		fibers.perform(sleep.sleep_op(0.001))
	end)
end


function tests.test_publisher_publishes_compact_component_and_no_workflow_timeline()
	fibers.run(function (scope)
		local bus = busmod.new()
		local conn = bus:connect()
		local m = model_mod.new(model_mod.service_initial('update', 1))

		local pub, err = publisher.start(scope, { conn = conn, model = m })
		assert_not_nil(pub, err)

		m:update(function (snap)
			snap.ready = true
			snap.state = 'running'
			snap.config = { components = { mcu = { component = 'mcu' } } }
			snap.jobs = {
				count = 1,
				order = { 'job-1' },
				by_id = {
					['job-1'] = {
						job_id = 'job-1',
						component = 'mcu', expected_image_id = 'mcu-image-test',
						state = 'awaiting_commit',
						artifact_ref = 'artifact-1',
						updated_seq = 2,
						last_event = { seq = 2, state = 'awaiting_commit', reason = 'stage_complete' },
						stage_result = {
							transfer = { digest_alg = 'xxhash32', digest = '12345678', size = 5 },
							reply = { transfer = { xfer_id = 'xfer-1', request_id = 'req-1', link_id = 'link-a', sent_bytes = 5 } },
						},
					},
				},
			}
			return snap
		end)

		local component = probe.wait_retained_payload(conn, topics.update_component('mcu'), { timeout = 0.3 })
		assert_eq(component.kind, 'update.component')
		assert_eq(component.current_job.job_id, 'job-1')
		assert_eq(component.current_job.state, 'awaiting_commit')
		assert_eq(component.jobs, nil)

		local summary = probe.wait_retained_payload(conn, topics.update_summary(), { timeout = 0.3 })
		assert_eq(summary.jobs.count, 1)
		assert_eq(summary.jobs.by_id, nil)
		assert_eq(summary.jobs.order, nil)
		assert_eq(summary.jobs.last.history, nil)
		assert_eq(summary.job.job_id, 'job-1')

		fibers.perform(sleep.sleep_op(0.05))
		local view = conn:retained_view({ 'state', 'workflow', '#' })
		assert_eq(view:get(topics.workflow_update_job_timeline('job-1')), nil)
		assert_eq(view:get(topics.workflow_update_job('job-1')), nil)
		view:close()

		pub:stop('test complete')
		fibers.perform(sleep.sleep_op(0.001))
	end)
end

return tests
