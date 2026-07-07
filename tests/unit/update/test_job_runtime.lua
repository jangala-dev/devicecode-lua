local fibers = require 'fibers'
local op = require 'fibers.op'
local job_runtime = require 'services.update.job_runtime'
local store_mod = require 'services.update.job_store_memory'

local tests = {}
local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a,b,msg) if a ~= b then fail(msg or ('expected '..tostring(b)..', got '..tostring(a))) end end
local function assert_true(v,msg) if v ~= true then fail(msg or ('expected true, got '..tostring(v))) end end
local function assert_not_nil(v,msg) if v == nil then fail(msg or 'expected non-nil') end end

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

function tests.test_single_job_startup_scrub_keeps_newest_recoverable_and_blitzes_others()
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
			delete_job_op = function (_, _) return op.always(true, nil) end,
		}
		local st, _, result = fibers.run_scope(function (scope)
			local rt = start_runtime(scope, { service_id = 'update', store = store })
			local adoption = rt:adoption()
			local active = rt:get('active')
			local staging = rt:get('staging')
			local commit = rt:get('commit')
			local ret = rt:get('ret')
			rt:cancel('test complete')
			return { adoption = adoption, active = active, staging = staging, commit = commit, ret = ret }
		end)
		assert_eq(st, 'ok')
		assert_eq(result.staging, nil)
		assert_eq(result.commit, nil)
		assert_eq(result.ret, nil)
		assert_eq(result.active.state, 'staging')
		assert_eq(result.active.adoption.action, 'resume_active_intent')
		assert_eq(result.adoption.single_job.kept_job_id, 'active')
		assert_eq(result.adoption.single_job.deleted_count, 3)
		assert_eq(#result.adoption.pruned, 3)
		assert_eq(#result.adoption.active_intent, 1)
		assert_true(#saves >= 1)
	end)
end

function tests.test_restart_adoption_fails_active_intent_after_configured_restart_limit()
	fibers.run(function ()
		local saves = {}
		local initial = { jobs = {
			active = {
				job_id = 'active', component = 'cm5', state = 'staging', created_seq = 1, updated_seq = 1,
				active_token = 'tok-stage',
				active_intent = { token = 'tok-stage', phase = 'stage', restart_count = 1 },
			},
		}, order = { 'active' }, next_seq = 10 }
		local store = {
			load_all_op = function () return op.always(initial, nil) end,
			save_job_op = function (_, job) saves[#saves + 1] = job; return op.always(true, nil) end,
		}
		local st, _, result = fibers.run_scope(function (scope)
			local rt = start_runtime(scope, {
				service_id = 'update',
				store = store,
				retention = { active_intent_restart_max = 1 },
			})
			local job = rt:get('active')
			local adoption = rt:adoption()
			rt:cancel('test complete')
			return { job = job, adoption = adoption }
		end)
		assert_eq(st, 'ok')
		assert_eq(result.job.state, 'failed')
		assert_eq(result.job.error, 'active_intent_restart_limit_exceeded')
		assert_eq(result.job.active_token, nil)
		assert_eq(result.job.active_intent, nil)
		assert_eq(result.job.active, nil)
		assert_eq(result.job.adoption.action, 'failed_restart_limit')
		assert_eq(result.job.adoption.restart_attempts, 2)
		assert_eq(#result.adoption.failed, 1)
		assert_true(#saves >= 1)
	end)
end

function tests.test_restart_adoption_ignores_legacy_history_after_compaction()
	fibers.run(function ()
		local saves = {}
		local initial = { jobs = {
			active = {
				job_id = 'active', component = 'cm5', state = 'staging', created_seq = 1, updated_seq = 1,
				active_token = 'tok-stage',
				active_intent = { token = 'tok-stage', phase = 'stage' },
				history = {
					{ seq = 1, state = 'staging', reason = 'restart_adoption_active_intent' },
				},
			},
		}, order = { 'active' }, next_seq = 10 }
		local store = {
			load_all_op = function () return op.always(initial, nil) end,
			save_job_op = function (_, job) saves[#saves + 1] = job; return op.always(true, nil) end,
		}
		local st, _, result = fibers.run_scope(function (scope)
			local rt = start_runtime(scope, {
				service_id = 'update',
				store = store,
				retention = { active_intent_restart_max = 1 },
			})
			local job = rt:get('active')
			rt:cancel('test complete')
			return { job = job }
		end)
		assert_eq(st, 'ok')
		assert_eq(result.job.state, 'staging')
		assert_eq(result.job.history, nil)
		assert_eq(result.job.adoption.action, 'resume_active_intent')
		assert_eq(result.job.adoption.restart_attempts, 1)
		assert_true(#saves >= 1)
	end)
end

function tests.test_restart_adoption_tolerates_missing_restart_counters()
	fibers.run(function ()
		local saves = {}
		local initial = { jobs = {
			active = {
				job_id = 'active', component = 'cm5', state = 'staging', created_seq = 1, updated_seq = 1,
				active_token = 'tok-stage',
				active_intent = { token = 'tok-stage', phase = 'stage' },
				runtime = {},
				adoption = {},
			},
		}, order = { 'active' }, next_seq = 10 }
		local store = {
			load_all_op = function () return op.always(initial, nil) end,
			save_job_op = function (_, job) saves[#saves + 1] = job; return op.always(true, nil) end,
		}
		local st, _, result = fibers.run_scope(function (scope)
			local rt = start_runtime(scope, {
				service_id = 'update',
				store = store,
				retention = { active_intent_restart_max = 1 },
			})
			local job = rt:get('active')
			rt:cancel('test complete')
			return { job = job }
		end)
		assert_eq(st, 'ok')
		assert_eq(result.job.state, 'staging')
		assert_eq(result.job.adoption.action, 'resume_active_intent')
		assert_eq(result.job.active_intent.restart_count, 1)
		assert_eq(result.job.active_intent.attempt, 1)
		assert_eq(result.job.active.attempt, 1)
		assert_eq(result.job.adoption.attempt, 1)
		assert_true(#saves >= 1)
	end)
end


function tests.test_restart_adoption_reads_legacy_attempt_field()
	fibers.run(function ()
		local saves = {}
		local initial = { jobs = {
			active = {
				job_id = 'active', component = 'cm5', state = 'staging', created_seq = 1, updated_seq = 1,
				active_token = 'tok-stage',
				active_intent = { token = 'tok-stage', phase = 'stage', attempt = 1 },
			},
		}, order = { 'active' }, next_seq = 10 }
		local store = {
			load_all_op = function () return op.always(initial, nil) end,
			save_job_op = function (_, job) saves[#saves + 1] = job; return op.always(true, nil) end,
		}
		local st, _, result = fibers.run_scope(function (scope)
			local rt = start_runtime(scope, {
				service_id = 'update',
				store = store,
				retention = { active_intent_restart_max = 1 },
			})
			local job = rt:get('active')
			rt:cancel('test complete')
			return { job = job }
		end)
		assert_eq(st, 'ok')
		assert_eq(result.job.state, 'failed')
		assert_eq(result.job.error, 'active_intent_restart_limit_exceeded')
		assert_eq(result.job.adoption.restart_attempts, 2)
		assert_eq(result.job.adoption.attempt, 2)
		assert_eq(result.job.result.restart_attempts, 2)
		assert_eq(result.job.result.active_intent, nil)
		assert_true(#saves >= 1)
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
		local rec = result.transitions.by_id[result.failed.transition_id]
		assert_eq(rec.state, 'failed')
		assert_eq(rec.error, 'save_failed')
		assert_true(rec.admitted, 'failed-after-admission should remain distinguishable from rejection')
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
		assert_true(#saved >= 2)
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


function tests.test_begin_commit_attempt_persists_awaiting_return_before_backend_commit()
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
		assert_eq(result.job.state, 'awaiting_return')
		assert_eq(result.job.next_step, 'reconcile')
		assert_eq(result.job.active_token, nil)
		assert_eq(result.job.active_intent, nil)
		assert_eq(result.job.commit_attempt.token, 'commit-token')
		assert_eq(result.job.commit_attempt.policy, 'idempotent_by_token')
		assert_eq(result.job.commit_attempt.acceptance, 'unknown')
		assert_eq(result.job.commit_result.tag, 'commit_pending')
		assert_eq(result.job.commit_result.commit_token, 'commit-token')
		assert_eq(#saved >= 2, true, 'adoption and awaiting_return commit attempt should be durably saved')
	end)
end

function tests.test_single_job_startup_scrub_keeps_newest_uncertain_commit_only()
	fibers.run(function ()
		local initial = { jobs = {
			idem = { job_id = 'idem', component = 'cm5', state = 'committing', created_seq = 1, updated_seq = 1, active_token = 'tok-idem', active_intent = { token = 'tok-idem', phase = 'commit', commit_token = 'ct-idem', commit_policy = 'idempotent_by_token' }, commit_attempt = { token = 'ct-idem', policy = 'idempotent_by_token' } },
			nodup = { job_id = 'nodup', component = 'cm5', state = 'committing', created_seq = 2, updated_seq = 2, active_token = 'tok-nodup', active_intent = { token = 'tok-nodup', phase = 'commit', commit_token = 'ct-nodup', commit_policy = 'no_duplicate' }, commit_attempt = { token = 'ct-nodup', policy = 'no_duplicate' } },
			missing = { job_id = 'missing', component = 'cm5', state = 'committing', created_seq = 3, updated_seq = 3, active_token = 'tok-missing', active_intent = { token = 'tok-missing', phase = 'commit', commit_token = 'ct-missing' } },
		}, order = { 'idem', 'nodup', 'missing' }, next_seq = 10 }
		local store = {
			load_all_op = function () return op.always(initial, nil) end,
			save_job_op = function (_, _) return op.always(true, nil) end,
			delete_job_op = function (_, _) return op.always(true, nil) end,
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
		assert_eq(result.idem, nil)
		assert_eq(result.nodup, nil)
		assert_not_nil(result.missing)
		assert_eq(result.missing.state, 'failed')
		assert_eq(result.missing.error, 'restart_commit_policy_missing')
		assert_eq(result.adoption.single_job.kept_job_id, 'missing')
		assert_eq(result.adoption.single_job.deleted_count, 2)
		assert_eq(#result.adoption.failed, 1)
	end)
end

function tests.test_job_runtime_blitzes_legacy_jobs_and_keeps_newest_terminal()
	fibers.run(function ()
		local initial = { jobs = {
			old1 = { job_id = 'old1', component = 'cm5', state = 'succeeded', created_seq = 1, updated_seq = 1, history = { { seq = 1, state = 'succeeded', reason = 'old' } } },
			old2 = { job_id = 'old2', component = 'cm5', state = 'failed', created_seq = 2, updated_seq = 2 },
			keep1 = { job_id = 'keep1', component = 'cm5', state = 'succeeded', created_seq = 3, updated_seq = 3 },
			keep2 = { job_id = 'keep2', component = 'cm5', state = 'cancelled', created_seq = 4, updated_seq = 4 },
			live = { job_id = 'live', component = 'cm5', state = 'created', created_seq = 5, updated_seq = 5 },
		}, order = { 'old1', 'old2', 'keep1', 'keep2', 'live' }, next_seq = 10 }
		local store = store_mod.new(initial)
		local st, _, result = fibers.run_scope(function (scope)
			local rt = start_runtime(scope, { service_id = 'update', store = store })
			local snapshot = rt:snapshot()
			local adoption = rt:adoption()
			rt:cancel('test complete')
			return { snapshot = snapshot, adoption = adoption }
		end)
		assert_eq(st, 'ok')
		assert_eq(result.snapshot.count, 1)
		assert_not_nil(result.snapshot.by_id.keep2)
		assert_eq(result.snapshot.by_id.keep2.history, nil)
		assert_eq(#result.adoption.pruned, 4)
	end)
end

function tests.test_job_runtime_keeps_newest_recoverable_before_terminal()
	fibers.run(function ()
		local initial = { jobs = {
			terminal = { job_id = 'terminal', component = 'cm5', state = 'succeeded', created_seq = 10, updated_seq = 10 },
			awaiting = { job_id = 'awaiting', component = 'cm5', state = 'awaiting_return', created_seq = 2, updated_seq = 2, commit_attempt = { token = 'ct' } },
			created = { job_id = 'created', component = 'cm5', state = 'created', created_seq = 99, updated_seq = 99 },
		}, order = { 'awaiting', 'terminal', 'created' }, next_seq = 100 }
		local store = store_mod.new(initial)
		local st, _, result = fibers.run_scope(function (scope)
			local rt = start_runtime(scope, { service_id = 'update', store = store })
			local snapshot = rt:snapshot()
			local adoption = rt:adoption()
			rt:cancel('test complete')
			return { snapshot = snapshot, adoption = adoption }
		end)
		assert_eq(st, 'ok')
		assert_eq(result.snapshot.count, 1)
		assert_not_nil(result.snapshot.by_id.awaiting)
		assert_eq(result.adoption.single_job.kept_job_id, 'awaiting')
		assert_eq(result.adoption.single_job.deleted_count, 2)
	end)
end

function tests.test_single_job_startup_scrub_prefers_terminal_over_plain_awaiting_commit()
	fibers.run(function ()
		local initial = { jobs = {
			terminal = { job_id = 'terminal', component = 'cm5', state = 'succeeded', created_seq = 10, updated_seq = 10 },
			awaiting = { job_id = 'awaiting', component = 'cm5', state = 'awaiting_commit', created_seq = 99, updated_seq = 99 },
		}, order = { 'terminal', 'awaiting' }, next_seq = 100 }
		local store = store_mod.new(initial)
		local st, _, result = fibers.run_scope(function (scope)
			local rt = start_runtime(scope, { service_id = 'update', store = store })
			local snapshot = rt:snapshot()
			local adoption = rt:adoption()
			rt:cancel('test complete')
			return { snapshot = snapshot, adoption = adoption }
		end)
		assert_eq(st, 'ok')
		assert_eq(result.snapshot.count, 1)
		assert_not_nil(result.snapshot.by_id.terminal)
		assert_eq(result.snapshot.by_id.awaiting, nil)
		assert_eq(result.adoption.single_job.kept_job_id, 'terminal')
	end)
end

function tests.test_restart_adoption_does_not_resave_plain_awaiting_commit()
	fibers.run(function ()
		local saves = 0
		local initial = { jobs = {
			awaiting = { job_id = 'awaiting', component = 'cm5', state = 'awaiting_commit', created_seq = 1, updated_seq = 1 },
		}, order = { 'awaiting' }, next_seq = 10 }
		local store = {
			load_all_op = function () return op.always(initial, nil) end,
			save_job_op = function () saves = saves + 1; return op.always(true, nil) end,
			delete_job_op = function () return op.always(true, nil) end,
		}
		local st, _, result = fibers.run_scope(function (scope)
			local rt = start_runtime(scope, { service_id = 'update', store = store })
			local job = rt:get('awaiting')
			local adoption = rt:adoption()
			rt:cancel('test complete')
			return { job = job, adoption = adoption }
		end)
		assert_eq(st, 'ok')
		assert_eq(result.job.state, 'awaiting_commit')
		assert_eq(result.job.adoption, nil)
		assert_eq(#result.adoption.awaiting_commit, 1)
		assert_eq(saves, 1, 'startup compaction save is allowed; adoption must not add a second save')
	end)
end

return tests
