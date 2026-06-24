local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'
local cond   = require 'fibers.cond'
local op     = require 'fibers.op'
local mailbox = require 'fibers.mailbox'
local busmod = require 'bus'

local service = require 'services.update.service'
local topics  = require 'services.update.topics'
local store_mod = require 'services.update.job_store_memory'
local active_runtime = require 'services.update.active_runtime'
local probe = require 'tests.support.bus_probe'
local queue = require 'devicecode.support.queue'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a, b, msg) if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end end
local function assert_true(v, msg) if v ~= true then fail(msg or ('expected true, got ' .. tostring(v))) end end
local function assert_not_nil(v, msg) if v == nil then fail(msg or 'expected non-nil value') end end
local function assert_nil(v, msg) if v ~= nil then fail(msg or ('expected nil, got ' .. tostring(v))) end end

local function start_service(root_scope, params)
	local bus = busmod.new()
	local svc_conn = bus:connect()
	local caller = bus:connect()
	local cfg_conn = bus:connect()
	local child = assert(root_scope:child())

	local ok, err = child:spawn(function (scope)
		params = params or {}
		params.conn = svc_conn
		params.service_id = params.service_id or 'update'
		if params.job_store == nil and params.job_store_kind == nil then
			params.job_store_kind = 'memory'
		end
		service.run(scope, params)
	end)
	assert_true(ok, err)

	fibers.perform(sleep.sleep_op(0.02))
	return child, caller, cfg_conn, bus
end


local function wait_job_visible(caller, job_id, timeout)
	local status
	local ok = probe.wait_until(function ()
		status = caller:call(topics.update_manager_rpc('status'), {}, { timeout = 0.05 })
		return status and status.snapshot and status.snapshot.jobs and status.snapshot.jobs.by_id[job_id] ~= nil
	end, { timeout = timeout or 0.5, interval = 0.01 })
	return ok, status
end

local function config_payload(namespace)
	return {
		rev = namespace == 'ns2' and 2 or 1,
		data = {
			schema = 'devicecode.update/1',
			namespace = namespace or 'ns1',
			components = {
				{ component = 'cm5' },
			},
		},
	}
end

local function blocking_store_for_create()
	local gate = cond.new()
	local state = {
		save_started = false,
		saved = {},
	}

	local backend = {}
	function backend:load_all_op()
		return op.always({ jobs = {}, order = {} }, nil)
	end
	function backend:save_job_op(job)
		state.save_started = true
		state.pending_job = job
		return gate:wait_op():wrap(function ()
			state.saved[job.job_id] = job
			return true, nil
		end)
	end

	state.gate = gate
	return backend, state
end

function tests.test_admitted_old_generation_create_completion_remains_durable_after_replacement()
	fibers.run(function (root_scope)
		local store, store_state = blocking_store_for_create()
		local child, caller, cfg_conn = start_service(root_scope, {
			job_store = store,
			config = config_payload('ns1'),
		})

		local reply, reply_err
		local ok_spawn = root_scope:spawn(function ()
			reply, reply_err = caller:call(topics.update_manager_rpc('create-job'), {
				job_id = 'old-job',
				component = 'cm5',
				artifact_ref = 'artifact-old-job',
			}, { timeout = 1.0 })
		end)
		assert_true(ok_spawn)

		assert_true(probe.wait_until(function () return store_state.save_started end, { timeout = 0.5, interval = 0.01 }), 'expected old create to reach store save')

		cfg_conn:retain(topics.config(), config_payload('ns2'))

		assert_true(probe.wait_until(function () return reply_err ~= nil end, { timeout = 0.8, interval = 0.01 }), 'expected old request to be finalised by generation cancellation')
		assert_eq(reply, nil)
		assert_eq(reply_err, 'config_changed')

		store_state.gate:signal()
		fibers.perform(sleep.sleep_op(0.05))

		local status = assert(caller:call(topics.update_manager_rpc('status'), {}, { timeout = 0.2 }))
		assert_eq(status.snapshot.config.namespace, 'ns2')
		assert_not_nil(status.snapshot.jobs.by_id['old-job'], 'admitted durable transition should still apply after generation replacement')
		assert_eq(status.snapshot.jobs.by_id['old-job'].state, 'created')

		child:cancel('test complete')
	end)
end

function tests.test_generation_replacement_does_not_cancel_accepted_active_work()
	fibers.run(function (root_scope)
		local active_started = cond.new()
		local active_finalised = false
		local active_finalised_cond = cond.new()
		local release_active = cond.new()

		local backend = {}
		function backend:stage_op(job)
			active_started:signal()
			return release_active:wait_op():wrap(function ()
				active_finalised = true
				active_finalised_cond:signal()
				return { job_id = job.job_id }
			end)
		end

		local child, caller, cfg_conn = start_service(root_scope, {
			config = config_payload('ns1'),
			backend = backend,
		})

		assert(caller:call(topics.update_manager_rpc('create-job'), { job_id = 'j1', component = 'cm5', artifact_ref = 'artifact-j1' }, { timeout = 0.5 }))
		fibers.perform(sleep.sleep_op(0.05))
		assert(caller:call(topics.update_manager_rpc('start-job'), { job_id = 'j1' }, { timeout = 0.5 }))
		fibers.perform(active_started:wait_op())

		cfg_conn:retain(topics.config(), config_payload('ns2'))
		fibers.perform(sleep.sleep_op(0.05))
		assert_eq(active_finalised, false, 'accepted active work must be service-owned, not cancelled by generation replacement')

		release_active:signal()
		fibers.perform(active_finalised_cond:wait_op())
		assert_eq(active_finalised, true)

		local status
		assert_true(probe.wait_until(function ()
			status = caller:call(topics.update_manager_rpc('status'), {}, { timeout = 0.05 })
			return status
				and status.snapshot
				and status.snapshot.config
				and status.snapshot.config.namespace == 'ns2'
				and status.snapshot.jobs
				and status.snapshot.jobs.by_id
				and status.snapshot.jobs.by_id.j1
				and status.snapshot.jobs.by_id.j1.state == 'awaiting_commit'
		end, { timeout = 0.8, interval = 0.01 }), 'expected current generation to observe active completion')

		child:cancel('test complete')
	end)
end

function tests.test_start_job_request_finalises_on_generation_cancellation()
	fibers.run(function (root_scope)
		local gate = cond.new()
		local start_save_seen = false
		local backend = { jobs = {} }

		function backend:load_all_op()
			return op.always({ jobs = self.jobs, order = {} }, nil)
		end
		function backend:save_job_op(job)
			if job.state == 'staging' then
				start_save_seen = true
				return gate:wait_op():wrap(function ()
					self.jobs[job.job_id] = job
					return true, nil
				end)
			end
			self.jobs[job.job_id] = job
			return op.always(true, nil)
		end

		local child, caller, cfg_conn = start_service(root_scope, {
			config = config_payload('ns1'),
			job_store = backend,
		})

		assert(caller:call(topics.update_manager_rpc('create-job'), { job_id = 'j1', component = 'cm5', artifact_ref = 'artifact-j1' }, { timeout = 0.5 }))
		fibers.perform(sleep.sleep_op(0.05))

		local reply, reply_err
		assert_true(root_scope:spawn(function ()
			reply, reply_err = caller:call(topics.update_manager_rpc('start-job'), { job_id = 'j1' }, { timeout = 1.0 })
		end))

		assert_true(probe.wait_until(function () return start_save_seen end, { timeout = 0.5, interval = 0.01 }), 'expected start-job save to be in progress')
		cfg_conn:retain(topics.config(), config_payload('ns2'))

		assert_true(probe.wait_until(function () return reply_err ~= nil end, { timeout = 0.8, interval = 0.01 }), 'expected start request to be finalised')
		assert_nil(reply)
		assert_eq(reply_err, 'config_changed')

		gate:signal()
		child:cancel('test complete')
	end)
end

function tests.test_accepted_start_is_saved_durably_before_reply()
	fibers.run(function (root_scope)
		local save_log = {}
		local backend = { jobs = {} }

		function backend:load_all_op()
			return op.always({ jobs = self.jobs, order = {} }, nil)
		end
		function backend:save_job_op(job)
			save_log[#save_log + 1] = { job_id = job.job_id, state = job.state }
			self.jobs[job.job_id] = job
			return op.always(true, nil)
		end

		local child, caller = start_service(root_scope, {
			config = config_payload('ns1'),
			job_store = backend,
			backend = { stage_op = function (_, job) return op.always({ job_id = job.job_id }, nil) end },
		})

		assert(caller:call(topics.update_manager_rpc('create-job'), { job_id = 'j1', component = 'cm5', artifact_ref = 'artifact-j1' }, { timeout = 0.5 }))
		fibers.perform(sleep.sleep_op(0.05))
		local reply = assert(caller:call(topics.update_manager_rpc('start-job'), { job_id = 'j1' }, { timeout = 0.5 }))
		assert_eq(reply.accepted, true)

		local saw_staging_save = false
		for _, row in ipairs(save_log) do
			if row.job_id == 'j1' and row.state == 'staging' then
				saw_staging_save = true
			end
		end
		assert_eq(saw_staging_save, true)

		child:cancel('test complete')
	end)
end

function tests.test_active_completion_and_ready_start_cannot_double_own_slot()
	fibers.run(function (root_scope)
		local run_count = 0
		local backend = {}
		function backend:stage_op(job)
			run_count = run_count + 1
			return op.always({ job_id = job.job_id }, nil)
		end

		local child, caller = start_service(root_scope, {
			config = config_payload('ns1'),
			backend = backend,
		})

		assert(caller:call(topics.update_manager_rpc('create-job'), { job_id = 'j1', component = 'cm5', artifact_ref = 'artifact-j1' }, { timeout = 0.5 }))
		assert(caller:call(topics.update_manager_rpc('create-job'), { job_id = 'j2', component = 'cm5', artifact_ref = 'artifact-j2' }, { timeout = 0.5 }))
		fibers.perform(sleep.sleep_op(0.05))
		fibers.perform(sleep.sleep_op(0.05))
		assert(caller:call(topics.update_manager_rpc('start-job'), { job_id = 'j1' }, { timeout = 0.5 }))

		local reply, err
		assert_true(probe.wait_until(function ()
			reply, err = caller:call(topics.update_manager_rpc('start-job'), { job_id = 'j2' }, { timeout = 0.05 })
			return reply and reply.accepted == true
		end, { timeout = 2.0, interval = 0.02 }), err or 'expected second start to be admitted after active completion')

		assert_true(probe.wait_until(function () return run_count >= 2 end, { timeout = 2.0, interval = 0.02 }), 'expected both jobs to run without double-owning the slot')

		child:cancel('test complete')
	end)
end


function tests.test_generation_event_selector_rechecks_completion_after_manager_wake()
	local priority_event = require 'devicecode.support.priority_event'

	local function staged_rx(name, item, bus, wakes_done)
		local rx = {
			_name = name,
			_item = item,
			_consumed = false,
			_closed = false,
			_why = nil,
		}

		function rx:why()
			return self._why
		end

		function rx:recv_op()
			return op.new_primitive(nil, function ()
				if self._consumed then
					return false
				end

				if self._closed then
					return true, nil
				end

				if bus.ready[self._name] then
					self._consumed = true
					self._closed = true
					self._why = 'closed'
					return true, self._item
				end

				return false
			end, function (suspension, wrap_fn)
				if wakes_done and not bus.fired then
					bus.fired = true
					bus.ready.done = true
					bus.ready.manager = true
					self._consumed = true
					self._closed = true
					self._why = 'closed'
					if suspension:waiting() then
						suspension:complete(wrap_fn, self._item)
					end
				end
			end)
		end

		return rx
	end

	fibers.run(function ()
		local bus = { ready = {}, fired = false }
		local pending = {}
		local done_rx = staged_rx('done', { kind = 'active_job_done', job_id = 'j1' }, bus, false)
		local manager_rx = staged_rx('manager', { id = 'start-j2' }, bus, true)

		local function map_done(ev)
			if ev == nil then return { kind = 'completion_queue_closed' } end
			return ev
		end

		local function map_manager(req)
			if req == nil then return { kind = 'manager_closed' } end
			return { kind = 'manager_request', request = req }
		end

		local function try_recv_now(rx, map)
			local item = queue.try_now(rx:recv_op(), NOT_READY)
			if item == NOT_READY then return nil end
			return map(item)
		end

		local function next_event_op()
			return priority_event.sources_op {
				label = 'update.generation.next_event.test',
				pending = pending,
				sources = {
					{
						name = 'done',
						try_now = function () return try_recv_now(done_rx, map_done) end,
						recv_op = function () return done_rx:recv_op():wrap(map_done) end,
					},
					{
						name = 'manager',
						try_now = function () return try_recv_now(manager_rx, map_manager) end,
						recv_op = function () return manager_rx:recv_op():wrap(map_manager) end,
					},
				},
			}
		end

		local first = fibers.perform(next_event_op())
		assert_eq(first.kind, 'active_job_done')
		assert_eq(first.job_id, 'j1')

		local second = fibers.perform(next_event_op())
		assert_eq(second.kind, 'manager_request')
		assert_eq(second.request.id, 'start-j2')
	end)
end

function tests.test_report_failure_does_not_lose_stored_active_completion()
	fibers.run(function (root_scope)
		local state = active_runtime.new_state()
		local done_tx = mailbox.new(0, { full = 'reject_newest' })
		local report_scope = assert(root_scope:child())
		local lease = assert(active_runtime.claim(state, { job_id = 'j1', generation = 1, phase = 'stage' }))

		local handle = assert(active_runtime.start_work(root_scope, state, {
			lease = lease,
			done_tx = done_tx,
			report_scope = report_scope,
			job = { job_id = 'j1', component = 'cm5', artifact_ref = 'artifact-j1' },
			backend = { stage_op = function () return op.always({ ok = true }, nil) end },
		}))

		local ev = fibers.perform(handle:outcome_op())
		assert_eq(ev.kind, 'active_job_done')
		assert_eq(ev.status, 'ok')
		assert_eq(ev.job_id, 'j1')

		report_scope:cancel('test complete')
	end)
end


function tests.test_active_completion_starts_durable_job_save()
	fibers.run(function (root_scope)
		local save_log = {}
		local backend = { jobs = {} }

		function backend:load_all_op()
			return op.always({ jobs = self.jobs, order = {} }, nil)
		end

		function backend:save_job_op(job)
			save_log[#save_log + 1] = { job_id = job.job_id, state = job.state }
			self.jobs[job.job_id] = job
			return op.always(true, nil)
		end

		local child, caller = start_service(root_scope, {
			config = config_payload('ns1'),
			job_store = backend,
			backend = { stage_op = function (_, job) return op.always({ job_id = job.job_id }, nil) end },
		})

		assert(caller:call(topics.update_manager_rpc('create-job'), { job_id = 'j1', component = 'cm5', artifact_ref = 'artifact-j1' }, { timeout = 0.5 }))
		fibers.perform(sleep.sleep_op(0.05))
		assert(caller:call(topics.update_manager_rpc('start-job'), { job_id = 'j1' }, { timeout = 0.5 }))

		local ok_wait = probe.wait_until(function ()
			for _, row in ipairs(save_log) do
				if row.job_id == 'j1' and row.state == 'awaiting_commit' then
					return true
				end
			end
			return false
		end, { timeout = 0.5, interval = 0.01 })

		assert_true(ok_wait, 'expected active completion to trigger durable awaiting_commit save')
		child:cancel('test complete')
	end)
end

function tests.test_service_owns_active_completion_persistence_after_generation_replacement()
	fibers.run(function (root_scope)
		local saves = {}
		local store = {
			load_all_op = function () return op.always({ jobs = {}, order = {} }, nil) end,
			save_job_op = function (_, job)
				saves[#saves + 1] = job
				return op.always(true, nil)
			end,
		}
		local release_active = cond.new()
		local active_started = cond.new()
		local backend = {}
		function backend:stage_op()
			active_started:signal()
			return release_active:wait_op():wrap(function ()
				return { accepted = true }
			end)
		end

		local child, caller, cfg_conn = start_service(root_scope, {
			job_store = store,
			config = config_payload('ns1'),
			backend = backend,
		})

		assert(caller:call(topics.update_manager_rpc('create-job'), { job_id = 'persist-active', component = 'cm5', artifact_ref = 'artifact-persist-active' }, { timeout = 0.5 }))
		fibers.perform(sleep.sleep_op(0.05))
		assert(caller:call(topics.update_manager_rpc('start-job'), { job_id = 'persist-active' }, { timeout = 0.5 }))
		fibers.perform(active_started:wait_op())

		cfg_conn:retain(topics.config(), config_payload('ns2'))
		fibers.perform(sleep.sleep_op(0.05))
		release_active:signal()

		assert_true(probe.wait_until(function ()
			for _, job in ipairs(saves) do
				if job.job_id == 'persist-active' and job.state == 'awaiting_commit' then
					return true
				end
			end
			return false
		end, { timeout = 0.8, interval = 0.01 }), 'expected service-owned active completion save after generation replacement')

		child:cancel('test complete')
	end)
end

return tests
