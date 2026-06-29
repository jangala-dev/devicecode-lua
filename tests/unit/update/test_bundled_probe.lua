local fibers = require 'fibers'
local mailbox = require 'fibers.mailbox'
local op = require 'fibers.op'
local bundled_probe = require 'services.update.bundled_probe'
local bundled_apply = require 'services.update.bundled_apply'
local bundled = require 'services.update.bundled'
local blob_source = require 'devicecode.blob_source'
local dcmcu_fixture = require 'tests.support.dcmcu_fixture'

local tests = {}
local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a,b,msg) if a ~= b then fail(msg or ('expected '..tostring(b)..', got '..tostring(a))) end end
local function assert_true(v,msg) if v ~= true then fail(msg or ('expected true, got '..tostring(v))) end end


local function import_store(ref, image_id)
	return {
		import_path_op = function (_, path, meta, opts)
			return op.always({ artifact_ref = ref or 'artifact-1', path = path, meta = meta, policy = opts and opts.policy }, nil)
		end,
		open_source_op = function (_, artifact_ref)
			assert_eq(artifact_ref, ref or 'artifact-1')
			return op.always(blob_source.from_string(dcmcu_fixture.make(image_id or 'mcu-image-new')), nil)
		end,
	}
end

local function fake_jobs()
	local state = { jobs = {}, transitions = {} }
	function state:ready_op()
		return op.always(true, nil)
	end
	function state:get(job_id)
		return self.jobs[job_id]
	end
	function state:admit_transition(cmd)
		self.transitions[#self.transitions + 1] = cmd
		local result
		if cmd.kind == 'create_job' then
			local payload = cmd.payload or {}
			if self.jobs[payload.job_id] then
				result = { status = 'rejected', reason = 'job_exists', job_id = payload.job_id }
			else
				local job = {
					job_id = payload.job_id,
					component = payload.component,
					expected_image_id = payload.expected_image_id,
					artifact_ref = payload.artifact_ref,
					artifact = payload.artifact,
					attempt = payload.attempt,
					metadata = payload.metadata,
					policy = payload.policy,
					state = 'created',
					next_step = 'start',
				}
				self.jobs[job.job_id] = job
				result = { status = 'persisted', job_id = job.job_id, job = job }
			end
		elseif cmd.kind == 'start_job' then
			local job = assert(self.jobs[cmd.job_id], 'start missing job')
			local phase = cmd.phase or 'stage'
			job.state = phase == 'commit' and 'committing' or 'staging'
			job.active_intent = { phase = phase, state = 'pending' }
			result = { status = 'persisted', job_id = job.job_id, phase = phase, job = job }
		elseif cmd.kind == 'discard_job' then
			local job = assert(self.jobs[cmd.job_id], 'discard missing job')
			self.jobs[cmd.job_id] = nil
			result = { status = 'persisted', job_id = cmd.job_id, job = job }
		else
			result = { status = 'rejected', reason = 'unsupported' }
		end
		return {
			outcome_op = function () return op.always(result, nil) end,
		}, nil
	end
	return state
end

local function probe_store()
	return {
		probe_op = function (_, source)
			return op.always({ identity = source.identity or 'desired-1' }, nil)
		end,
	}
end

function tests.test_bundled_probe_reports_completion_without_inline_policy()
	fibers.run(function (scope)
		local tx, rx = mailbox.new(4, { full = 'reject_newest' })
		local handle = assert(bundled_probe.start({
			lifetime_scope = scope,
			report_scope = scope,
			service_id = 'update',
			generation = 7,
			component = 'cm5',
			artifact_store = probe_store(),
			source = { identity = 'image-a' },
			done_tx = tx,
		}))
		assert_true(handle ~= nil)
		local ev = fibers.perform(rx:recv_op())
		assert_eq(ev.kind, 'bundled_probe_done')
		assert_eq(ev.status, 'ok')
		assert_eq(ev.result.desired.identity, 'image-a')
	end)
end

function tests.test_bundled_coordinator_starts_probe_and_applies_stored_result()
	fibers.run(function (scope)
		local tx, rx = mailbox.new(4, { full = 'reject_newest' })
		local co = bundled.new({ service_id = 'update', generation = 3 })
		assert(co:start_probe({
			lifetime_scope = scope,
			report_scope = scope,
			component = 'cm5',
			artifact_store = probe_store(),
			source = { identity = 'desired-cm5' },
			done_tx = tx,
		}))
		local ev = fibers.perform(rx:recv_op())
		assert_true(co:handle_probe_done(ev))
		local snap = co:snapshot()
		assert_eq(snap.state.cm5, 'desired_known')
		assert_eq(snap.desired.cm5.identity, 'desired-cm5')
	end)
end


function tests.test_bundled_probe_imports_fixed_file_to_artifact_ref()
	fibers.run(function (scope)
		local tx, rx = mailbox.new(4, { full = 'reject_newest' })
		assert(bundled_probe.start({
			lifetime_scope = scope,
			report_scope = scope,
			service_id = 'update',
			generation = 8,
			component = 'mcu',
			artifact_store = import_store('mcu-artifact'),
			source = { kind = 'file', path = '/artifacts/mcu.dcmcu', policy = 'transient_only' },
			done_tx = tx,
		}))
		local ev = fibers.perform(rx:recv_op())
		assert_eq(ev.kind, 'bundled_probe_done')
		assert_eq(ev.status, 'ok')
		assert_eq(ev.result.artifact_ref, 'mcu-artifact')
		assert_eq(ev.result.desired.expected_image_id, 'mcu-image-new')
		assert_eq(ev.result.desired.path, '/artifacts/mcu.dcmcu')
		assert_eq(ev.result.desired.policy, 'transient_only')
	end)
end

function tests.test_bundled_apply_creates_and_optionally_starts_normal_job()
	fibers.run(function (scope)
		local tx, rx = mailbox.new(4, { full = 'reject_newest' })
		local jobs = fake_jobs()
		assert(bundled_apply.start({
			lifetime_scope = scope,
			report_scope = scope,
			service_id = 'update',
			generation = 9,
			component = 'mcu',
			jobs = jobs,
			spec = { component = 'mcu', source = { metadata = { format = 'dcmcu-v1' } }, job = { start = 'auto', commit = 'auto' } },
			desired = { artifact_ref = 'mcu-artifact', expected_image_id = 'mcu-image-new', artifact = { artifact_ref = 'mcu-artifact', expected_image_id = 'mcu-image-new' } },
			done_tx = tx,
		}))
		local ev = fibers.perform(rx:recv_op())
		assert_eq(ev.kind, 'bundled_apply_done')
		assert_eq(ev.status, 'ok')
		assert_eq(ev.result.job_id, 'bundled-mcu')
		assert_eq(jobs.jobs['bundled-mcu'].artifact_ref, 'mcu-artifact')
		assert_eq(jobs.jobs['bundled-mcu'].expected_image_id, 'mcu-image-new')
		assert_eq(jobs.jobs['bundled-mcu'].policy.commit, 'auto')
		assert_eq(jobs.jobs['bundled-mcu'].attempt, 1)
		assert_eq(jobs.jobs['bundled-mcu'].metadata.bundled_attempt, 1)
		assert_eq(jobs.jobs['bundled-mcu'].state, 'staging')
		assert_eq(#jobs.transitions, 2)
	end)
end

function tests.test_bundled_coordinator_probe_then_apply_policy()
	fibers.run(function (scope)
		local tx, rx = mailbox.new(4, { full = 'reject_newest' })
		local jobs = fake_jobs()
		local co = bundled.new({
			service_id = 'update',
			generation = 10,
			config = {
				enabled = true,
				components = {
					mcu = {
						component = 'mcu',
						source = { kind = 'file', path = 'mcu.dcmcu' },
						job = { create_if = 'image_differs', start = 'auto', commit = 'auto', max_attempts = 3 },
					},
				},
			},
		})
		assert(co:start_missing_probes({
			lifetime_scope = scope,
			report_scope = scope,
			artifact_store = import_store('mcu-artifact'),
			done_tx = tx,
		}))
		local probe_ev = fibers.perform(rx:recv_op())
		assert_true(co:handle_probe_done(probe_ev))
		assert(co:start_ready_applies({
			lifetime_scope = scope,
			report_scope = scope,
			jobs = jobs,
			observer_snapshot = { by_id = { mcu = { state = { software = { image_id = 'mcu-image-old' } } } } },
			done_tx = tx,
		}))
		local apply_ev = fibers.perform(rx:recv_op())
		assert_true(co:handle_apply_done(apply_ev))
		local snap = co:snapshot()
		assert_eq(snap.state.mcu, 'applied')
		assert_eq(jobs.jobs['bundled-mcu'].state, 'staging')
		assert_eq(jobs.jobs['bundled-mcu'].expected_image_id, 'mcu-image-new')
	end)
end


function tests.test_bundled_apply_skips_when_running_image_matches_artifact()
	fibers.run(function (scope)
		local tx = mailbox.new(4, { full = 'reject_newest' })
		local jobs = fake_jobs()
		local co = bundled.new({ service_id = 'update', generation = 11, config = { enabled = true, components = { mcu = {
			component = 'mcu',
			source = { kind = 'file', path = '/artifacts/mcu.dcmcu', policy = 'transient_only' },
			job = { create_if = 'image_differs', start = 'auto', commit = 'auto', max_attempts = 3 },
		} } } })
		assert_true(co:handle_probe_done({
			kind = 'bundled_probe_done', generation = 11, component = 'mcu', status = 'ok',
			result = { desired = { artifact_ref = 'mcu-artifact', expected_image_id = 'mcu-image-new' } },
		}))
		local started = assert(co:start_ready_applies({
			lifetime_scope = scope,
			report_scope = scope,
			jobs = jobs,
			observer_snapshot = { by_id = { mcu = { state = { software = { image_id = 'mcu-image-new' } } } } },
			done_tx = tx,
		}))
		assert_eq(#started, 0)
		assert_eq(co:snapshot().state.mcu, 'already_current')
		assert_eq(#jobs.transitions, 0)
	end)
end

function tests.test_bundled_apply_waits_for_current_image_before_creating_job()
	fibers.run(function (scope)
		local tx, rx = mailbox.new(4, { full = 'reject_newest' })
		local jobs = fake_jobs()
		local co = bundled.new({ service_id = 'update', generation = 12, config = { enabled = true, components = { mcu = {
			component = 'mcu',
			source = { kind = 'file', path = '/artifacts/mcu.dcmcu', policy = 'transient_only' },
			job = { create_if = 'image_differs', start = 'auto', commit = 'auto', max_attempts = 3 },
		} } } })
		assert_true(co:handle_probe_done({
			kind = 'bundled_probe_done', generation = 12, component = 'mcu', status = 'ok',
			result = { desired = { artifact_ref = 'mcu-artifact', expected_image_id = 'mcu-image-new' } },
		}))
		local none = assert(co:start_ready_applies({ lifetime_scope = scope, report_scope = scope, jobs = jobs, observer_snapshot = {}, done_tx = tx }))
		assert_eq(#none, 0)
		assert_eq(co:snapshot().state.mcu, 'pending_current_image')
		local started = assert(co:start_ready_applies({
			lifetime_scope = scope,
			report_scope = scope,
			jobs = jobs,
			observer_snapshot = { by_id = { mcu = { state = { software = { image_id = 'mcu-image-old' } } } } },
			done_tx = tx,
		}))
		assert_eq(#started, 1)
		local ev = fibers.perform(rx:recv_op())
		assert_true(co:handle_apply_done(ev))
		assert_eq(jobs.jobs['bundled-mcu'].state, 'staging')
	end)
end


function tests.test_bundled_apply_supersedes_terminal_changed_image_job()
	fibers.run(function (scope)
		local tx, rx = mailbox.new(4, { full = 'reject_newest' })
		local jobs = fake_jobs()
		jobs.jobs['bundled-mcu'] = { job_id = 'bundled-mcu', component = 'mcu', expected_image_id = 'mcu-image-old', state = 'failed' }
		assert(bundled_apply.start({
			lifetime_scope = scope,
			report_scope = scope,
			service_id = 'update',
			generation = 13,
			component = 'mcu',
			jobs = jobs,
			spec = { component = 'mcu', source = { metadata = { format = 'dcmcu-v1' } }, job = { job_id = 'bundled-mcu', start = 'manual', supersede = 'same_job_if_image_changed' } },
			desired = { artifact_ref = 'mcu-artifact', expected_image_id = 'mcu-image-new', artifact = { artifact_ref = 'mcu-artifact', expected_image_id = 'mcu-image-new' } },
			done_tx = tx,
		}))
		local ev = fibers.perform(rx:recv_op())
		assert_eq(ev.kind, 'bundled_apply_done')
		assert_eq(ev.status, 'ok')
		assert_eq(jobs.transitions[1].kind, 'discard_job')
		assert_eq(jobs.transitions[2].kind, 'create_job')
		assert_eq(jobs.jobs['bundled-mcu'].expected_image_id, 'mcu-image-new')
		assert_eq(jobs.jobs['bundled-mcu'].state, 'created')
	end)
end


function tests.test_bundled_apply_retries_terminal_same_image_until_attempt_limit()
	fibers.run(function (scope)
		local tx, rx = mailbox.new(4, { full = 'reject_newest' })
		local jobs = fake_jobs()
		jobs.jobs['bundled-mcu'] = {
			job_id = 'bundled-mcu', component = 'mcu', expected_image_id = 'mcu-image-new',
			state = 'failed', attempt = 1, metadata = { bundled_attempt = 1 },
		}
		assert(bundled_apply.start({
			lifetime_scope = scope,
			report_scope = scope,
			service_id = 'update',
			generation = 14,
			component = 'mcu',
			jobs = jobs,
			spec = { component = 'mcu', source = { metadata = { format = 'dcmcu-v1' } }, job = { job_id = 'bundled-mcu', start = 'auto', commit = 'auto', max_attempts = 3, supersede = 'same_job_if_image_changed' } },
			desired = { artifact_ref = 'mcu-artifact', expected_image_id = 'mcu-image-new', artifact = { artifact_ref = 'mcu-artifact', expected_image_id = 'mcu-image-new' } },
			done_tx = tx,
		}))
		local ev = fibers.perform(rx:recv_op())
		assert_eq(ev.kind, 'bundled_apply_done')
		assert_eq(ev.status, 'ok')
		assert_eq(jobs.transitions[1].kind, 'discard_job')
		assert_eq(jobs.transitions[2].kind, 'create_job')
		assert_eq(jobs.transitions[3].kind, 'start_job')
		assert_eq(jobs.jobs['bundled-mcu'].expected_image_id, 'mcu-image-new')
		assert_eq(jobs.jobs['bundled-mcu'].attempt, 2)
		assert_eq(jobs.jobs['bundled-mcu'].metadata.bundled_attempt, 2)
		assert_eq(jobs.jobs['bundled-mcu'].policy.attempt, 2)
		assert_eq(jobs.jobs['bundled-mcu'].state, 'staging')
	end)
end


function tests.test_bundled_apply_resets_attempts_after_previous_success_for_same_image()
	fibers.run(function (scope)
		local tx, rx = mailbox.new(4, { full = 'reject_newest' })
		local jobs = fake_jobs()
		jobs.jobs['bundled-mcu'] = {
			job_id = 'bundled-mcu', component = 'mcu', expected_image_id = 'mcu-image-new',
			state = 'succeeded', attempt = 30, metadata = { bundled_attempt = 30 },
		}
		assert(bundled_apply.start({
			lifetime_scope = scope,
			report_scope = scope,
			service_id = 'update',
			generation = 16,
			component = 'mcu',
			jobs = jobs,
			spec = { component = 'mcu', source = { metadata = { format = 'dcmcu-v1' } }, job = { job_id = 'bundled-mcu', start = 'auto', commit = 'auto', max_attempts = 30, supersede = 'same_job_if_image_changed' } },
			desired = { artifact_ref = 'mcu-artifact', expected_image_id = 'mcu-image-new', artifact = { artifact_ref = 'mcu-artifact', expected_image_id = 'mcu-image-new' } },
			done_tx = tx,
		}))
		local ev = fibers.perform(rx:recv_op())
		assert_eq(ev.kind, 'bundled_apply_done')
		assert_eq(ev.status, 'ok')
		assert_eq(jobs.transitions[1].kind, 'discard_job')
		assert_eq(jobs.transitions[2].kind, 'create_job')
		assert_eq(jobs.transitions[3].kind, 'start_job')
		assert_eq(jobs.jobs['bundled-mcu'].expected_image_id, 'mcu-image-new')
		assert_eq(jobs.jobs['bundled-mcu'].attempt, 1)
		assert_eq(jobs.jobs['bundled-mcu'].metadata.bundled_attempt, 1)
		assert_eq(jobs.jobs['bundled-mcu'].policy.attempt, 1)
		assert_eq(jobs.jobs['bundled-mcu'].state, 'staging')
	end)
end

function tests.test_bundled_apply_stops_terminal_same_image_after_attempt_limit()
	fibers.run(function (scope)
		local tx, rx = mailbox.new(4, { full = 'reject_newest' })
		local jobs = fake_jobs()
		jobs.jobs['bundled-mcu'] = {
			job_id = 'bundled-mcu', component = 'mcu', expected_image_id = 'mcu-image-new',
			state = 'failed', attempt = 3, metadata = { bundled_attempt = 3 },
		}
		assert(bundled_apply.start({
			lifetime_scope = scope,
			report_scope = scope,
			service_id = 'update',
			generation = 15,
			component = 'mcu',
			jobs = jobs,
			spec = { component = 'mcu', source = { metadata = { format = 'dcmcu-v1' } }, job = { job_id = 'bundled-mcu', start = 'auto', commit = 'auto', max_attempts = 3, supersede = 'same_job_if_image_changed' } },
			desired = { artifact_ref = 'mcu-artifact', expected_image_id = 'mcu-image-new', artifact = { artifact_ref = 'mcu-artifact', expected_image_id = 'mcu-image-new' } },
			done_tx = tx,
		}))
		local ev = fibers.perform(rx:recv_op())
		assert_eq(ev.kind, 'bundled_apply_done')
		assert_eq(ev.status, 'failed')
		assert_eq(ev.primary, 'bundled_retry_exhausted:3/3')
		assert_eq(#jobs.transitions, 0)
		assert_eq(jobs.jobs['bundled-mcu'].state, 'failed')
	end)
end

return tests
