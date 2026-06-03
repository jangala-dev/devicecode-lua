local fibers = require 'fibers'
local sleep = require 'fibers.sleep'
local op = require 'fibers.op'
local cond = require 'fibers.cond'
local job_runtime = require 'services.update.job_runtime'
local store_mod = require 'services.update.job_store_memory'

local tests = {}
local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a,b,msg) if a ~= b then fail(msg or ('expected '..tostring(b)..', got '..tostring(a))) end end
local function assert_true(v,msg) if v ~= true then fail(msg or ('expected true, got '..tostring(v))) end end
local function assert_not_nil(v,msg) if v == nil then fail(msg or 'expected non-nil') end end

local function wait_until(fn, opts)
	opts = opts or {}
	local deadline = fibers.now() + (opts.timeout or 0.5)
	local interval = opts.interval or 0.005
	while fibers.now() < deadline do
		if fn() then return true end
		fibers.perform(sleep.sleep_op(interval))
	end
	return false
end

local function start_runtime(scope, params)
	local rt = assert(job_runtime.start(scope, params or {}))
	local ready, err = fibers.perform(rt:ready_op())
	assert_true(ready, err)
	return rt
end

local function perform_transition(rt, cmd)
	local handle, admit_err = rt:admit_transition(cmd)
	assert_not_nil(handle, admit_err)
	return assert(fibers.perform(handle:outcome_op()))
end

function tests.test_transition_lifecycle_records_persisted_and_rejected_states()
	fibers.run(function ()
		local st, _, result = fibers.run_scope(function (scope)
			local rt = start_runtime(scope, { service_id = 'update', store = store_mod.new() })
			local created = perform_transition(rt, {
				kind = 'create_job',
				generation = 1,
				payload = { job_id = 'j1', component = 'cm5' },
			})
			assert_eq(created.status, 'persisted')
			local rejected = perform_transition(rt, {
				kind = 'start_job',
				generation = 1,
				job_id = 'missing',
			})
			assert_eq(rejected.status, 'rejected')
			local transitions = rt:transition_snapshot()
			rt:cancel('test complete')
			return { created = created, rejected = rejected, transitions = transitions }
		end)
		assert_eq(st, 'ok')
		local created_rec = result.transitions.by_id[result.created.transition_id]
		local rejected_rec = result.transitions.by_id[result.rejected.transition_id]
		assert_not_nil(created_rec, 'created transition should be recorded')
		assert_not_nil(rejected_rec, 'rejected transition should be recorded')
		assert_eq(created_rec.state, 'persisted')
		assert_eq(created_rec.plan_kind, 'save_job')
		assert_eq(rejected_rec.state, 'rejected')
		assert_eq(rejected_rec.error, 'not_found')
		assert_eq(rejected_rec.admitted, nil, 'rejected-before-admission must not retain admitted=true')
	end)
end

function tests.test_restart_adoption_persists_decisions_and_marks_interrupted_jobs_failed()
	fibers.run(function ()
		local saves = {}
		local initial = { jobs = {
			staging = { job_id = 'staging', component = 'cm5', state = 'staging', created_seq = 1, updated_seq = 1 },
			active = { job_id = 'active', component = 'cm5', state = 'staging', created_seq = 4, updated_seq = 4, active_token = 'tok-stage', active_intent = { token = 'tok-stage', phase = 'stage' } },
			commit = { job_id = 'commit', component = 'cm5', state = 'awaiting_commit', created_seq = 2, updated_seq = 2 },
			ret = { job_id = 'ret', component = 'cm5', state = 'awaiting_return', created_seq = 3, updated_seq = 3 },
		}, order = { 'staging', 'commit', 'ret', 'active' }, next_seq = 10 }
		local store = {
			load_all_op = function () return op.always(initial, nil) end,
			save_job_op = function (_, job) saves[#saves + 1] = job; return op.always(true, nil) end,
		}
		local st, _, result = fibers.run_scope(function (scope)
			local rt = start_runtime(scope, { service_id = 'update', store = store })
			local adoption = rt:adoption()
			local failed = rt:get('staging')
			local active = rt:get('active')
			local commit = rt:get('commit')
			local ret = rt:get('ret')
			rt:cancel('test complete')
			return { adoption = adoption, failed = failed, active = active, commit = commit, ret = ret }
		end)
		assert_eq(st, 'ok')
		assert_eq(result.failed.state, 'failed')
		assert_eq(result.failed.active_intent, nil)
		assert_eq(result.active.state, 'staging')
		assert_eq(result.active.adoption.action, 'resume_active_intent')
		assert_eq(result.commit.state, 'awaiting_commit')
		assert_eq(result.commit.adoption.action, 'kept_committable')
		assert_eq(result.ret.state, 'awaiting_return')
		assert_eq(result.ret.adoption.action, 'reconcile_required')
		assert_eq(#result.adoption.failed, 1)
		assert_eq(#result.adoption.active_intent, 1)
		assert_eq(#result.adoption.awaiting_commit, 1)
		assert_eq(#result.adoption.awaiting_return, 1)
		assert_eq(#saves, 4, 'adoption decisions should be durably saved')
	end)
end



function tests.test_failed_after_admission_keeps_admitted_lifecycle_marker()
	fibers.run(function ()
		local initial = { jobs = {
			j1 = { job_id = 'j1', component = 'cm5', state = 'created', created_seq = 1, updated_seq = 1 },
		}, order = { 'j1' }, next_seq = 10 }
		local store = {
			load_all_op = function () return op.always(initial, nil) end,
			save_job_op = function () return op.always(nil, 'save_failed') end,
		}
		local st, _, result = fibers.run_scope(function (scope)
			local rt = start_runtime(scope, { service_id = 'update', store = store })
			local failed = perform_transition(rt, {
				kind = 'start_job',
				generation = 1,
				job_id = 'j1',
			})
			local transitions = rt:transition_snapshot()
			rt:cancel('test complete')
			return { failed = failed, transitions = transitions }
		end)
		assert_eq(st, 'ok')
		assert_eq(result.failed.status, 'failed')
		assert_eq(result.failed.reason, 'job_store_save_failed:save_failed')
		assert_eq(result.failed.store_op, 'save_job_op')
		assert_eq(result.failed.store_err, 'job_store_save_failed:save_failed')
		local rec = result.transitions.by_id[result.failed.transition_id]
		assert_eq(rec.state, 'failed')
		assert_eq(rec.error, 'job_store_save_failed:save_failed')
		assert_eq(rec.store_op, 'save_job_op')
		assert_eq(rec.store_err, 'job_store_save_failed:save_failed')
		assert_true(rec.admitted, 'failed-after-admission should remain distinguishable from rejection')
	end)
end

function tests.test_retryable_save_failure_stays_pending_and_recovers()
	fibers.run(function ()
		local allow_save = false
		local attempts = 0
		local saved
		local store = {
			save_job_op = function (_, job)
				attempts = attempts + 1
				if not allow_save then return op.always(nil, 'control_store_put_timeout') end
				saved = job
				return op.always(true, nil)
			end,
		}

		local st, _, result = fibers.run_scope(function (scope)
			local rt = start_runtime(scope, {
				service_id = 'update',
				store = store,
				persistence_retry_backoff = 0.005,
			})
			local handle, admit_err = rt:admit_transition({
				kind = 'create_job',
				generation = 1,
				payload = { job_id = 'j-pending', component = 'cm5', artifact_ref = 'artifact-1' },
			})
			assert_not_nil(handle, admit_err)

			assert_true(wait_until(function ()
				local pending = rt:persistence_snapshot()
				return pending and pending.retry_attempts and pending.retry_attempts >= 1
			end), 'expected retryable persistence failure to become visible')

			local pending = rt:persistence_snapshot()
			local snapshot = rt:model_snapshot()
			local transition = snapshot.transitions.by_id[handle:transition_id()]
			assert_eq(rt:persistence_pending(), true)
			assert_eq(pending.store_op, 'save_job_op')
			assert_eq(pending.store_err, 'job_store_save_failed:control_store_put_timeout')
			assert_eq(pending.job_id, 'j-pending')
			assert_eq(pending.retry_mode, 'indefinite')
			assert_eq(pending.dependency, 'job_store')
			assert_not_nil(pending.first_failed_at)
			assert_not_nil(pending.last_attempt_at)
			assert_true(pending.retry_attempts >= 1)
			assert_eq(transition.state, 'persisting')
			assert_eq(transition.persistence_pending, true)
			assert_eq(transition.retry_mode, 'indefinite')
			assert_eq(transition.dependency, 'job_store')

			local second, second_err = rt:admit_transition({
				kind = 'create_job',
				generation = 1,
				payload = { job_id = 'j-blocked', component = 'cm5', artifact_ref = 'artifact-2' },
			})
			assert_eq(second, nil)
			assert_eq(second_err, 'job_persistence_pending')

			allow_save = true
			local persisted = fibers.perform(handle:outcome_op())
			local after = rt:model_snapshot()
			rt:cancel('test complete')
			return { persisted = persisted, after = after }
		end)

		assert_eq(st, 'ok')
		assert_eq(result.persisted.status, 'persisted')
		assert_eq(result.persisted.job_id, 'j-pending')
		assert_eq(result.after.persistence, nil)
		assert_not_nil(saved, 'expected job to be saved after retry recovery')
		assert_true(attempts >= 2, 'expected at least one retry before recovery')
	end)
end

function tests.test_route_missing_store_failure_is_not_persistence_retry()
	fibers.run(function ()
		local store = {
			save_job_op = function ()
				return op.always(nil, 'no_route')
			end,
		}

		local st, _, result = fibers.run_scope(function (scope)
			local rt = start_runtime(scope, {
				service_id = 'update',
				store = store,
				persistence_retry_backoff = 0.005,
			})
			local failed = perform_transition(rt, {
				kind = 'create_job',
				generation = 1,
				payload = { job_id = 'j-route', component = 'cm5', artifact_ref = 'artifact-route' },
			})
			local transitions = rt:transition_snapshot()
			local persistence = rt:persistence_snapshot()
			rt:cancel('test complete')
			return { failed = failed, transitions = transitions, persistence = persistence }
		end)

		assert_eq(st, 'ok')
		assert_eq(result.failed.status, 'failed')
		assert_eq(result.failed.reason, 'job_store_save_failed:no_route')
		assert_eq(result.persistence, nil)
		local rec = result.transitions.by_id[result.failed.transition_id]
		assert_eq(rec.state, 'failed')
		assert_eq(rec.store_err, 'job_store_save_failed:no_route')
		assert_eq(rec.persistence_pending, nil)
	end)
end

function tests.test_discard_job_allows_only_unowned_created_jobs_by_default()
	fibers.run(function ()
		local st, _, result = fibers.run_scope(function (scope)
			local rt = start_runtime(scope, { service_id = 'update', store = store_mod.new() })
			local created = perform_transition(rt, {
				kind = 'create_job',
				generation = 1,
				payload = { job_id = 'j-created', component = 'cm5', artifact_ref = 'artifact-created' },
			})
			local discarded = perform_transition(rt, {
				kind = 'discard_job',
				generation = 1,
				job_id = 'j-created',
				reason = 'upload_start_failed:slot_busy',
			})

			perform_transition(rt, {
				kind = 'create_job',
				generation = 1,
				payload = { job_id = 'j-active', component = 'cm5', artifact_ref = 'artifact-active' },
			})
			perform_transition(rt, {
				kind = 'start_job',
				generation = 1,
				job_id = 'j-active',
			})
			local active_rejected = perform_transition(rt, {
				kind = 'discard_job',
				generation = 1,
				job_id = 'j-active',
				reason = 'unsafe_active_discard',
			})

			perform_transition(rt, {
				kind = 'create_job',
				generation = 1,
				payload = { job_id = 'j-staging', component = 'cm5', artifact_ref = 'artifact-staging' },
			})
			perform_transition(rt, {
				kind = 'patch_job',
				generation = 1,
				job_id = 'j-staging',
				patch = { state = 'staging', next_step = nil },
			})
			local staging_rejected = perform_transition(rt, {
				kind = 'discard_job',
				generation = 1,
				job_id = 'j-staging',
			})

			perform_transition(rt, {
				kind = 'create_job',
				generation = 1,
				payload = { job_id = 'j-return', component = 'cm5', artifact_ref = 'artifact-return' },
			})
			perform_transition(rt, {
				kind = 'patch_job',
				generation = 1,
				job_id = 'j-return',
				patch = { state = 'awaiting_return', next_step = 'reconcile' },
			})
			local return_rejected = perform_transition(rt, {
				kind = 'discard_job',
				generation = 1,
				job_id = 'j-return',
			})
			local forced = perform_transition(rt, {
				kind = 'discard_job',
				generation = 1,
				job_id = 'j-return',
				force = true,
				reason = 'admin_force_discard',
			})

			local snapshot = rt:snapshot()
			rt:cancel('test complete')
			return {
				created = created,
				discarded = discarded,
				active_rejected = active_rejected,
				staging_rejected = staging_rejected,
				return_rejected = return_rejected,
				forced = forced,
				snapshot = snapshot,
			}
		end)

		assert_eq(st, 'ok')
		assert_eq(result.created.status, 'persisted')
		assert_eq(result.discarded.status, 'persisted')
		assert_eq(result.snapshot.by_id['j-created'], nil)
		assert_eq(result.active_rejected.status, 'rejected')
		assert_eq(result.active_rejected.reason, 'job_not_discardable')
		assert_eq(result.staging_rejected.status, 'rejected')
		assert_eq(result.staging_rejected.reason, 'job_not_discardable')
		assert_eq(result.return_rejected.status, 'rejected')
		assert_eq(result.return_rejected.reason, 'job_not_discardable')
		assert_eq(result.forced.status, 'persisted')
		assert_not_nil(result.snapshot.by_id['j-active'])
		assert_not_nil(result.snapshot.by_id['j-staging'])
		assert_eq(result.snapshot.by_id['j-return'], nil)
	end)
end

function tests.test_healthy_inflight_transition_queueing_is_intentional()
	fibers.run(function ()
		local save_entered = cond.new()
		local release_save = cond.new()
		local saved = {}
		local store = {
			save_job_op = function (_, job)
				saved[#saved + 1] = job.job_id
				if job.job_id == 'j-first' then
					save_entered:signal()
					return release_save:wait_op():wrap(function () return true, nil end)
				end
				return op.always(true, nil)
			end,
		}

		local st, _, result = fibers.run_scope(function (scope)
			local rt = start_runtime(scope, { service_id = 'update', store = store })
			local first = assert(rt:admit_transition({
				kind = 'create_job',
				generation = 1,
				payload = { job_id = 'j-first', component = 'cm5', artifact_ref = 'artifact-1' },
			}))
			fibers.perform(save_entered:wait_op())
			local second, second_err = rt:admit_transition({
				kind = 'create_job',
				generation = 1,
				payload = { job_id = 'j-second', component = 'cm5', artifact_ref = 'artifact-2' },
			})
			assert_not_nil(second, second_err)
			assert_eq(rt:persistence_pending(), false)
			release_save:signal()
			local first_result = fibers.perform(first:outcome_op())
			local second_result = fibers.perform(second:outcome_op())
			rt:cancel('test complete')
			return { first = first_result, second = second_result }
		end)

		assert_eq(st, 'ok')
		assert_eq(result.first.status, 'persisted')
		assert_eq(result.second.status, 'persisted')
		assert_eq(saved[1], 'j-first')
		assert_eq(saved[2], 'j-second')
	end)
end

function tests.test_submit_transition_rejects_before_ready_without_recording_admission()
	fibers.run(function ()
		local st, _, result = fibers.run_scope(function (scope)
			local rt = assert(job_runtime.start(scope, { service_id = 'update', store = store_mod.new() }))
			local handle, admit_err = rt:admit_transition {
				kind = 'create_job',
				generation = 1,
				payload = { job_id = 'j1', component = 'cm5' },
			}
			assert_eq(handle, nil)
			local rejected = { status = 'rejected', reason = admit_err }
			local transitions = rt:transition_snapshot()
			rt:cancel('test complete')
			return { rejected = rejected, transitions = transitions }
		end)
		assert_eq(st, 'ok')
		assert_eq(result.rejected.status, 'rejected')
		assert_eq(result.rejected.reason, 'job_runtime_not_ready')
		assert_eq(result.transitions.count, 0, 'pre-ready submission is not admitted into durable lifecycle')
	end)
end


function tests.test_job_runtime_rejects_stale_generation_before_admission()
	fibers.run(function ()
		local st, _, result = fibers.run_scope(function (scope)
			local rt = start_runtime(scope, {
				service_id = 'update',
				store = store_mod.new(),
				current_generation = 2,
			})
			local rejected = perform_transition(rt, {
				kind = 'create_job',
				generation = 1,
				payload = { job_id = 'old', component = 'cm5' },
			})
			local transitions = rt:transition_snapshot()
			rt:cancel('test complete')
			return { rejected = rejected, transitions = transitions }
		end)
		assert_eq(st, 'ok')
		assert_eq(result.rejected.status, 'rejected')
		assert_eq(result.rejected.reason, 'stale_generation')
		local rec = result.transitions.by_id[result.rejected.transition_id]
		assert_not_nil(rec, 'stale transition should be recorded as rejected')
		assert_eq(rec.state, 'rejected')
		assert_eq(rec.error, 'stale_generation')
		assert_eq(rec.admitted, nil)
	end)
end

function tests.test_job_runtime_allows_old_generation_active_apply_by_token()
	fibers.run(function ()
		local initial = { jobs = {
			j1 = {
				job_id = 'j1',
				component = 'cm5',
				state = 'staging',
				created_seq = 1,
				updated_seq = 1,
				active_token = 'tok1',
				active_intent = { token = 'tok1', phase = 'stage', generation = 1 },
			},
		}, order = { 'j1' }, next_seq = 10 }
		local saved = {}
		local store = {
			load_all_op = function () return op.always(initial, nil) end,
			save_job_op = function (_, job) saved[#saved + 1] = job; return op.always(true, nil) end,
		}
		local st, _, result = fibers.run_scope(function (scope)
			local rt = start_runtime(scope, {
				service_id = 'update',
				store = store,
				current_generation = 2,
			})
			local applied = perform_transition(rt, {
				kind = 'apply_active_result',
				generation = 1,
				job_id = 'j1',
				phase = 'stage',
				token = 'tok1',
				event = {
					kind = 'active_job_done',
					generation = 1,
					job_id = 'j1',
					phase = 'stage',
					token = 'tok1',
					status = 'ok',
					result = { tag = 'staged', staged = { component = 'cm5' } },
				},
			})
			local job = rt:get('j1')
			rt:cancel('test complete')
			return { applied = applied, job = job }
		end)
		assert_eq(st, 'ok')
		assert_eq(result.applied.status, 'persisted')
		assert_eq(result.job.state, 'awaiting_commit')
		assert_eq(result.job.active_token, nil)
		assert_eq(#saved, 2)
	end)
end

function tests.test_job_runtime_transition_admission_is_not_an_op_builder()
	local f = assert(io.open('../src/services/update/job_runtime.lua', 'r'))
	local src = f:read('*a')
	f:close()
	if src:find('submit_transition_op', 1, true) or src:find('transition_op', 1, true) then
		fail('job_runtime should expose immediate admit_transition, not transition Op compatibility helpers')
	end
	if not src:find('function Runtime:admit_transition', 1, true) then
		fail('job_runtime should expose admit_transition')
	end
	local body = src:match('function Runtime:admit_transition%(.+function Runtime:terminate') or ''
	if body:find('op.guard', 1, true) or body:find('fibers.perform', 1, true) then
		fail('admit_transition must remain strictly immediate')
	end
end


function tests.test_begin_commit_attempt_persists_policy_and_token_before_backend_commit()
	fibers.run(function ()
		local saved = {}
		local initial = { jobs = {
			j1 = {
				job_id = 'j1', component = 'cm5', state = 'committing',
				created_seq = 1, updated_seq = 1, active_token = 'active-token',
				active_intent = { token = 'active-token', phase = 'commit', commit_token = 'commit-token', commit_policy = 'idempotent_by_token' },
				commit_attempt = { token = 'commit-token', policy = 'idempotent_by_token', acceptance = 'unknown' },
			},
		}, order = { 'j1' }, next_seq = 10 }
		local store = {
			load_all_op = function () return op.always(initial, nil) end,
			save_job_op = function (_, job) saved[#saved + 1] = job; return op.always(true, nil) end,
		}
		local st, _, result = fibers.run_scope(function (scope)
			local rt = start_runtime(scope, { service_id = 'update', store = store })
			local begun = perform_transition(rt, {
				kind = 'begin_commit_attempt',
				job_id = 'j1',
				phase = 'commit',
				token = 'active-token',
				commit_token = 'commit-token',
				commit_policy = 'idempotent_by_token',
			})
			local job = rt:get('j1')
			rt:cancel('test complete')
			return { begun = begun, job = job }
		end)
		assert_eq(st, 'ok')
		assert_eq(result.begun.status, 'persisted')
		assert_eq(result.begun.commit_token, 'commit-token')
		assert_eq(result.job.commit_attempt.token, 'commit-token')
		assert_eq(result.job.commit_attempt.policy, 'idempotent_by_token')
		assert_eq(result.job.commit_attempt.acceptance, 'unknown')
		assert_eq(#saved >= 2, true, 'adoption and begin attempt should be durably saved')
	end)
end

function tests.test_restart_adoption_uses_commit_policy_for_uncertain_commits()
	fibers.run(function ()
		local initial = { jobs = {
			idem = {
				job_id = 'idem', component = 'cm5', state = 'committing',
				created_seq = 1, updated_seq = 1, active_token = 'tok-idem',
				active_intent = { token = 'tok-idem', phase = 'commit', commit_token = 'ct-idem', commit_policy = 'idempotent_by_token' },
				commit_attempt = { token = 'ct-idem', policy = 'idempotent_by_token', acceptance = 'unknown' },
			},
			nodup = {
				job_id = 'nodup', component = 'cm5', state = 'committing',
				created_seq = 2, updated_seq = 2, active_token = 'tok-nodup',
				active_intent = { token = 'tok-nodup', phase = 'commit', commit_token = 'ct-nodup', commit_policy = 'no_duplicate' },
				commit_attempt = { token = 'ct-nodup', policy = 'no_duplicate', acceptance = 'unknown' },
			},
			missing = {
				job_id = 'missing', component = 'cm5', state = 'committing',
				created_seq = 3, updated_seq = 3, active_token = 'tok-missing',
				active_intent = { token = 'tok-missing', phase = 'commit' },
			},
		}, order = { 'idem', 'nodup', 'missing' }, next_seq = 20 }
		local store = {
			load_all_op = function () return op.always(initial, nil) end,
			save_job_op = function () return op.always(true, nil) end,
		}
		local st, _, result = fibers.run_scope(function (scope)
			local rt = start_runtime(scope, { service_id = 'update', store = store })
			local adoption = rt:adoption()
			local idem = rt:get('idem')
			local nodup = rt:get('nodup')
			local missing = rt:get('missing')
			rt:cancel('test complete')
			return { adoption = adoption, idem = idem, nodup = nodup, missing = missing }
		end)
		assert_eq(st, 'ok')
		assert_eq(result.idem.state, 'committing')
		assert_eq(result.idem.active_intent.token, 'tok-idem')
		assert_eq(result.idem.active_intent.commit_token, 'ct-idem')
		assert_eq(result.nodup.state, 'awaiting_return')
		assert_eq(result.nodup.active_intent, nil)
		assert_eq(result.nodup.adoption.action, 'reconcile_required')
		assert_eq(result.missing.state, 'failed')
		assert_eq(result.missing.error, 'restart_commit_policy_missing')
		assert_eq(#result.adoption.active_intent, 1)
		assert_eq(#result.adoption.awaiting_return, 1)
		assert_eq(#result.adoption.failed, 1)
	end)
end

return tests
