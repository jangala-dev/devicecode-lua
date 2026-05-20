-- services/update/active_job.lua
--
-- Active update worker bodies.
--
-- These functions run inside an active-job scope. They may perform backend Ops
-- and observer waits because the active-job scope owns the update phase
-- lifetime. They return one result table on success and let ordinary failures
-- escape through the scope machinery.

local safe = require 'coxpcall'
local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'

local M = {}

local function backend_method(backend, name, required)
	if type(backend) ~= 'table' then
		error('active_job: backend required', 0)
	end

	local fn = backend[name]
	if type(fn) == 'function' then
		return fn
	end

	if required then
		error('update backend missing ' .. name, 0)
	end

	return nil
end

local function perform_backend_op(backend, name, required, ...)
	local fn = backend_method(backend, name, required)
	if not fn then
		return nil, nil
	end

	local result, err = fibers.perform(fn(backend, ...))
	if result == nil then
		error(err or (name .. '_failed'), 0)
	end

	return result, nil
end

local function base_ctx(params, phase)
	local ctx = {}
	for k, v in pairs(params.ctx or {}) do
		ctx[k] = v
	end
	ctx.phase = phase
	ctx.lease = params.lease
	return ctx
end

local function require_job(params, label)
	local job = params and params.job or nil
	if type(job) ~= 'table' then
		error(label .. ': job required', 0)
	end
	if type(job.job_id) ~= 'string' or job.job_id == '' then
		error(label .. ': job.job_id required', 0)
	end
	return job
end

local function stage_context(params)
	local backend = assert(params.backend, 'active_job.stage: backend required')
	local job = require_job(params, 'active_job.stage')
	local ctx = base_ctx(params, 'stage')
	return backend, job, ctx
end

function M.stage(_scope, params)
	params = params or {}
	local backend, job, ctx = stage_context(params)
	local staged = perform_backend_op(backend, 'stage_op', true, job, ctx)

	return {
		tag       = 'staged',
		job_id    = job.job_id,
		component = job.component,
		staged    = staged,
	}
end


local COMMIT_POLICIES = {
	idempotent_by_token = true,
	no_duplicate = true,
}

local function backend_commit_policy(backend)
	local policy
	if type(backend.commit_capabilities) == 'function' then
		local caps = backend:commit_capabilities()
		policy = type(caps) == 'table' and caps.policy or caps
	elseif type(backend.commit_policy) == 'function' then
		local caps = backend:commit_policy()
		policy = type(caps) == 'table' and caps.policy or caps
	elseif type(backend.commit_policy) == 'string' then
		policy = backend.commit_policy
	elseif type(backend.commit) == 'table' then
		policy = backend.commit.policy
	end

	if not COMMIT_POLICIES[policy] then
		error('update backend commit policy must be idempotent_by_token or no_duplicate', 0)
	end

	return policy
end

local function perform_transition(jobs, cmd, unavailable_reason)
	if type(jobs) ~= 'table' or type(jobs.admit_transition) ~= 'function' then
		error(unavailable_reason or 'job_runtime_unavailable', 0)
	end

	local handle, admit_err = jobs:admit_transition(cmd)
	if not handle then
		error(admit_err or 'job_transition_admission_failed', 0)
	end

	local result, err = fibers.perform(handle:outcome_op())
	if not result or result.status ~= 'persisted' then
		error(err or (result and result.reason) or 'job_transition_persist_failed', 0)
	end

	return result
end

local function begin_commit_attempt(params, job, ctx, policy)
	local jobs = params.jobs or (params.ctx and params.ctx.jobs)
	local lease = params.lease
	local active_token = lease and lease.token or job.active_token or (job.active_intent and job.active_intent.token)
	local commit_token = (job.commit_attempt and job.commit_attempt.token)
		or (job.active_intent and job.active_intent.commit_token)
		or active_token

	local result = perform_transition(jobs, {
		kind = 'begin_commit_attempt',
		generation = (lease and lease.generation) or job.generation,
		job_id = job.job_id,
		phase = 'commit',
		token = active_token,
		commit_token = commit_token,
		commit_policy = policy,
		pre_commit = ctx.pre_commit,
		reason = 'active_commit_begin_attempt',
	}, 'active_job.commit: job_runtime required before backend commit')

	ctx.commit_token = result.commit_token or commit_token
	ctx.commit_policy = result.commit_policy or policy
	return result
end

local function persist_commit_accepted(params, job, ctx, policy, accepted)
	local jobs = params.jobs or (params.ctx and params.ctx.jobs)
	local lease = params.lease
	local active_token = lease and lease.token or job.active_token or (job.active_intent and job.active_intent.token)
	local ok, result = safe.pcall(function ()
		return perform_transition(jobs, {
			kind = 'commit_accepted',
			generation = (lease and lease.generation) or job.generation,
			job_id = job.job_id,
			phase = 'commit',
			token = active_token,
			commit_token = ctx.commit_token,
			commit_policy = ctx.commit_policy or policy,
			accepted = accepted,
			reason = 'active_commit_accepted',
		}, 'active_job.commit: job_runtime required after backend commit')
	end)
	if ok then return result end
	local reason = tostring(result or 'commit_accepted_persist_failed')
	error('critical_inconsistent_commit_acceptance: ' .. reason, 0)
end

function M.commit(_scope, params)
	params = params or {}
	local backend = assert(params.backend, 'active_job.commit: backend required')
	local job = require_job(params, 'active_job.commit')
	local ctx = base_ctx(params, 'commit')
	local policy = backend_commit_policy(backend)
	local pre_commit = perform_backend_op(backend, 'pre_commit_record_op', false, job, ctx)
	if pre_commit ~= nil then ctx.pre_commit = pre_commit end
	local attempt = begin_commit_attempt(params, job, ctx, policy)

	local accepted = perform_backend_op(backend, 'commit_op', true, job, ctx)
	local persisted = persist_commit_accepted(params, job, ctx, policy, accepted)

	return {
		tag           = 'commit_started',
		job_id        = job.job_id,
		component     = job.component,
		commit        = accepted,
		accepted      = true,
		commit_token  = ctx.commit_token or attempt.commit_token,
		commit_policy = ctx.commit_policy or policy,
		persisted     = persisted,
	}
end

local function reconcile_eval_fn(backend)
	local fn = backend_method(backend, 'evaluate_reconcile', false)
	if fn then return fn end
	fn = backend_method(backend, 'evaluate', false)
	if fn then return fn end
	error('update backend missing evaluate_reconcile', 0)
end

local function evaluate_reconcile(backend, job, snapshot, ctx)
	local result = reconcile_eval_fn(backend)(backend, job, snapshot, ctx)
	if type(result) ~= 'table' then
		return { done = false }
	end
	return result
end

local function deadline_reached(deadline)
	return deadline ~= nil and fibers.now() >= deadline
end

local function timeout_result(job, deadline)
	return {
		tag      = 'reconcile_timeout',
		job_id   = job.job_id,
		deadline = deadline,
	}
end

local function observer_closed_result(job, reason)
	return {
		tag    = 'reconcile_observer_closed',
		job_id = job.job_id,
		reason = reason or 'observer_closed',
	}
end

local function normalise_reconcile_done(job, result)
	result.job_id = result.job_id or job.job_id

	if result.tag == nil then
		if result.ok == false then
			result.tag = 'reconciled_failure'
		else
			result.tag = 'reconciled_success'
		end
	end

	return result
end

local function wait_for_reconcile_progress(observer, seen, deadline, poll_s)
	if observer and type(observer.changed_op) == 'function' then
		local which, version, snapshot, reason = fibers.perform(fibers.named_choice {
			changed = observer:changed_op(seen),
			timeout = deadline and sleep.sleep_until_op(deadline) or fibers.never(),
		})

		if which == 'timeout' then
			return 'timeout'
		end

		if version == nil then
			return 'observer_closed', reason
		end

		return 'changed', version, snapshot
	end

	fibers.perform(sleep.sleep_op(poll_s or 0.05))
	return 'polled'
end

function M.reconcile(_scope, params)
	params = params or {}
	local backend = assert(params.backend, 'active_job.reconcile: backend required')
	local job = require_job(params, 'active_job.reconcile')
	local observer = params.observer
	local deadline = params.deadline
	local seen = observer and observer.version and observer:version() or 0
	local ctx = base_ctx(params, 'reconcile')

	while true do
		local snapshot = observer and observer.snapshot and observer:snapshot() or nil
		local result = evaluate_reconcile(backend, job, snapshot, ctx)

		if result.done then
			return normalise_reconcile_done(job, result)
		end

		if deadline_reached(deadline) then
			return timeout_result(job, deadline)
		end

		local status, a, b = wait_for_reconcile_progress(observer, seen, deadline, params.poll_s)
		if status == 'timeout' then
			return timeout_result(job, deadline)
		end
		if status == 'observer_closed' then
			return observer_closed_result(job, a)
		end
		if status == 'changed' then
			seen = a or seen
			ctx.last_observed = b
		end
	end
end

function M.run(scope, params)
	params = params or {}
	local phase = params.phase or 'stage'

	if phase == 'stage' then
		return M.stage(scope, params)
	end

	if phase == 'commit' then
		return M.commit(scope, params)
	end

	if phase == 'reconcile' then
		return M.reconcile(scope, params)
	end

	error('unknown active job phase: ' .. tostring(phase), 0)
end

return M
