local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'
local op     = require 'fibers.op'
local observe = require 'services.update.observe'
local active_job = require 'services.update.active_job'

local tests = {}
local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a,b,msg) if a ~= b then fail(msg or ('expected '..tostring(b)..', got '..tostring(a))) end end
local function assert_true(v,msg) if v ~= true then fail(msg or ('expected true, got '..tostring(v))) end end

function tests.test_observer_changed_op_wakes_with_snapshot_copy()
	fibers.run(function ()
		local obs = observe.new({ components = { cm5 = { component = 'cm5' } } })
		local seen = obs:version()
		local got
		fibers.spawn(function ()
			local version, snapshot = fibers.perform(obs:changed_op(seen))
			got = { version = version, snapshot = snapshot }
		end)
		obs:update_component('cm5', { boot_id = 'b1' })
		fibers.perform(sleep.sleep_op(0.01))
		assert_true(got ~= nil, 'expected observer wait to wake')
		assert_eq(got.snapshot.by_id.cm5.state.boot_id, 'b1')
		got.snapshot.by_id.cm5.state.boot_id = 'mutated'
		assert_eq(obs:snapshot().by_id.cm5.state.boot_id, 'b1')
	end)
end

function tests.test_reconcile_worker_waits_on_component_observer()
	fibers.run(function (scope)
		local obs = observe.new({ components = { cm5 = { component = 'cm5' } } })
		local backend = {}
		function backend:evaluate_reconcile(job, snapshot)
			local cm5 = snapshot and snapshot.by_id and snapshot.by_id.cm5
			if cm5 and cm5.state and cm5.state.version == 'new' then
				return { done = true, tag = 'reconciled_success', observed = cm5.state }
			end
			return { done = false }
		end
		fibers.spawn(function ()
			fibers.perform(sleep.sleep_op(0.02))
			obs:update_component('cm5', { version = 'new' })
		end)
		local result = active_job.reconcile(scope, {
			backend = backend,
			job = { job_id = 'j1', component = 'cm5' },
			observer = obs,
			deadline = fibers.now() + 1,
		})
		assert_eq(result.tag, 'reconciled_success')
		assert_eq(result.job_id, 'j1')
		assert_eq(result.observed.version, 'new')
	end)
end


function tests.test_stage_worker_runs_single_stage_op()
	fibers.run(function (scope)
		local called = 0
		local backend = {}
		function backend:stage_op(job, ctx)
			called = called + 1
			assert_eq(ctx.phase, 'stage')
			return op.always({ staged = true, preflight = { compatible = true }, prepared = { handle = 'prepared' } }, nil)
		end

		local result = active_job.stage(scope, {
			backend = backend,
			job = { job_id = 'j1', component = 'cm5' },
		})

		assert_eq(result.tag, 'staged')
		assert_eq(result.staged.staged, true)
		assert_eq(result.staged.preflight.compatible, true)
		assert_eq(result.staged.prepared.handle, 'prepared')
		assert_eq(called, 1)
	end)
end
function tests.test_reconcile_worker_returns_observer_closed_result()
	fibers.run(function (scope)
		local obs = observe.new({ components = { cm5 = { component = 'cm5' } } })
		local backend = {}
		function backend:evaluate_reconcile()
			return { done = false }
		end

		fibers.spawn(function ()
			fibers.perform(sleep.sleep_op(0.02))
			obs:terminate('observer_lost')
		end)

		local result = active_job.reconcile(scope, {
			backend = backend,
			job = { job_id = 'j1', component = 'cm5' },
			observer = obs,
			deadline = fibers.now() + 1,
		})

		assert_eq(result.tag, 'reconcile_observer_closed')
		assert_eq(result.reason, 'observer_lost')
	end)
end

function tests.test_reconcile_worker_returns_deadline_result()
	fibers.run(function (scope)
		local backend = {}
		function backend:evaluate_reconcile()
			return { done = false }
		end

		local result = active_job.reconcile(scope, {
			backend = backend,
			job = { job_id = 'j1', component = 'cm5' },
			deadline = fibers.now() + 0.02,
			poll_s = 0.005,
		})

		assert_eq(result.tag, 'reconcile_timeout')
		assert_eq(result.job_id, 'j1')
	end)
end


function tests.test_commit_worker_persists_attempt_before_backend_commit_and_passes_token()
	fibers.run(function (scope)
		local order = {}
		local jobs = {}
		function jobs:admit_transition(cmd)
			if cmd.kind == 'begin_commit_attempt' then
				order[#order + 1] = 'begin_attempt'
				assert_eq(cmd.token, 'active-token')
				assert_eq(cmd.commit_token, 'active-token')
				assert_eq(cmd.commit_policy, 'idempotent_by_token')
			elseif cmd.kind == 'commit_accepted' then
				order[#order + 1] = 'commit_accepted'
				assert_eq(cmd.commit_token, 'active-token')
				assert_eq(cmd.commit_policy, 'idempotent_by_token')
			else
				error('unexpected transition '..tostring(cmd.kind), 0)
			end
			return { outcome_op = function () return op.always({ status = 'persisted', commit_token = cmd.commit_token, commit_policy = cmd.commit_policy }, nil) end }, nil
		end
		local backend = {}
		function backend:commit_capabilities()
			return { policy = 'idempotent_by_token' }
		end
		function backend:commit_op(job, ctx)
			order[#order + 1] = 'backend_commit'
			assert_eq(ctx.commit_token, 'active-token')
			assert_eq(ctx.commit_policy, 'idempotent_by_token')
			return op.always({ accepted = true, token = ctx.commit_token }, nil)
		end
		local result = active_job.commit(scope, {
			backend = backend,
			jobs = jobs,
			lease = { token = 'active-token', generation = 1 },
			job = { job_id = 'j1', component = 'cm5', state = 'committing', active_token = 'active-token' },
		})
		assert_eq(result.tag, 'commit_started')
		assert_eq(result.commit_token, 'active-token')
		assert_eq(table.concat(order, ','), 'begin_attempt,backend_commit,commit_accepted')
	end)
end

function tests.test_commit_worker_rejects_backend_without_commit_policy()
	fibers.run(function (scope)
		local backend = { commit_op = function () return op.always({ accepted = true }, nil) end }
		local ok, err = pcall(function ()
			active_job.commit(scope, {
				backend = backend,
				jobs = { admit_transition = function () return { outcome_op = function () return op.always({ status = 'persisted' }, nil) end }, nil end },
				lease = { token = 'active-token', generation = 1 },
				job = { job_id = 'j1', component = 'cm5', state = 'committing', active_token = 'active-token' },
			})
		end)
		assert_eq(ok, false)
		assert_true(tostring(err):find('commit policy', 1, true) ~= nil, 'expected explicit commit policy error')
	end)
end


function tests.test_commit_worker_surfaces_critical_inconsistent_outcome_after_backend_acceptance()
	fibers.run(function (scope)
		local calls = 0
		local jobs = {}
		function jobs:admit_transition(cmd)
			calls = calls + 1
			if cmd.kind == 'begin_commit_attempt' then
				return { outcome_op = function () return op.always({ status = 'persisted', commit_token = cmd.commit_token, commit_policy = cmd.commit_policy }, nil) end }, nil
			end
			if cmd.kind == 'commit_accepted' then
				return { outcome_op = function () return op.always({ status = 'failed', reason = 'save_failed' }, nil) end }, nil
			end
			error('unexpected transition '..tostring(cmd.kind), 0)
		end
		local backend = {}
		function backend:commit_capabilities()
			return { policy = 'idempotent_by_token' }
		end
		function backend:commit_op(_, ctx)
			return op.always({ accepted = true, token = ctx.commit_token }, nil)
		end
		local ok, err = pcall(function ()
			active_job.commit(scope, {
				backend = backend,
				jobs = jobs,
				lease = { token = 'active-token', generation = 1 },
				job = { job_id = 'j1', component = 'cm5', state = 'committing', active_token = 'active-token' },
			})
		end)
		assert_eq(ok, false)
		assert_true(tostring(err):find('critical_inconsistent_commit_acceptance', 1, true) ~= nil, 'expected critical inconsistent-outcome failure')
		assert_eq(calls, 2)
	end)
end

return tests
