-- services/update/bundled_apply.lua
--
-- Scoped bundled-policy application.
--
-- This worker owns the blocking durable transitions for the fixed-path policy:
-- create a normal update job from the imported artifact and optionally persist
-- a start intent.  Active execution remains service-owned by active_runtime.

local fibers = require 'fibers'
local scoped_work = require 'devicecode.support.scoped_work'
local queue = require 'devicecode.support.queue'
local tablex = require 'shared.table'

local M = {}

local function copy(v) return tablex.deep_copy(v) end

local function merge(a, b)
	local out = copy(a or {})
	for k, v in pairs(b or {}) do out[k] = copy(v) end
	return out
end

local function artifact_ref_of(artifact)
	if type(artifact) ~= 'table' then return nil end
	return artifact.artifact_ref or artifact.ref or artifact.id
end

local TERMINAL = { succeeded = true, failed = true, cancelled = true, timed_out = true, superseded = true, discarded = true }

local function job_policy(spec)
	spec = spec or {}
	local job = copy(spec.job or {})
	if job.job_id == nil then job.job_id = spec.job_id or (spec.source and spec.source.job_id) end
	if job.create_if == nil then
		if spec.auto_create ~= nil then
			job.create_if = spec.auto_create == true and 'always' or 'never'
		else
			job.create_if = 'image_differs'
		end
	end
	if job.start == nil then job.start = spec.auto_start == true and 'auto' or 'manual' end
	if job.commit == nil then job.commit = 'manual' end
	if job.reconcile == nil then job.reconcile = 'required' end
	if job.supersede == nil then job.supersede = 'same_job_if_image_changed' end
	return job
end

local function transition(jobs, cmd)
	if type(jobs) ~= 'table' or type(jobs.admit_transition) ~= 'function' then
		return nil, 'job_runtime_unavailable'
	end
	local handle, err = jobs:admit_transition(cmd)
	if not handle then return nil, err or 'job_transition_admission_failed' end
	return fibers.perform(handle:outcome_op())
end

local function create_payload(spec, desired)
	desired = desired or {}
	local artifact = copy(desired.artifact or desired.desired or desired)
	local component = assert(spec.component, 'bundled_apply component required')
	local source = spec.source or {}
	local policy = job_policy(spec)
	local job_id = policy.job_id or spec.job_id or source.job_id or ('bundled-' .. component)
	local metadata = merge({
		source = 'bundled',
		bundled = true,
	}, source.metadata or source.meta)
	metadata = merge(metadata, spec.metadata)

	local expected_image_id = desired.expected_image_id or (type(artifact) == 'table' and artifact.expected_image_id)
	if component == 'mcu' and (type(expected_image_id) ~= 'string' or expected_image_id == '') then
		error('expected_image_id_required', 0)
	end
	return {
		job_id = job_id,
		component = component,
		expected_image_id = expected_image_id,
		artifact = artifact,
		artifact_ref = desired.artifact_ref or artifact_ref_of(artifact),
		metadata = metadata,
		policy = policy,
		auto_start = policy.start == 'auto',
	}
end

local function discard_existing_job(params, job_id)
	local result, err = transition(params.jobs, {
		kind = 'discard_job',
		generation = params.generation,
		job_id = job_id,
		reason = 'bundled_supersede_changed_image',
	})
	if not result then return nil, err or 'bundled_supersede_discard_failed' end
	if result.status ~= 'persisted' then return nil, result.reason or 'bundled_supersede_discard_rejected' end
	return result, nil
end

local function create_job(params, payload)
	local result, err = transition(params.jobs, {
		kind = 'create_job',
		generation = params.generation,
		payload = payload,
		reason = 'bundled_create_job',
	})

	if not result then return nil, err or 'bundled_create_job_failed' end
	if result.status == 'persisted' then return result, nil end

	if result.status == 'rejected' and result.reason == 'job_exists' then
		local job = params.jobs:get(payload.job_id)
		if job ~= nil then
			return { status = 'existing', job_id = payload.job_id, job = job }, nil
		end
	end

	return nil, result.reason or err or 'bundled_create_job_failed'
end

local function create_or_reuse_job(params, payload)
	local existing = params.jobs:get(payload.job_id)
	if existing ~= nil then
		if existing.expected_image_id == payload.expected_image_id then
			return {
				status = 'existing',
				job_id = payload.job_id,
				job = existing,
			}, nil
		end
		local supersede = type(payload.policy) == 'table' and payload.policy.supersede or nil
		if TERMINAL[existing.state] == true and supersede == 'same_job_if_image_changed' then
			local discarded, derr = discard_existing_job(params, payload.job_id)
			if not discarded then return nil, derr end
			local created, cerr = create_job(params, payload)
			if created then created.superseded = discarded end
			return created, cerr
		end
		return nil, 'bundled_existing_job_image_mismatch'
	end

	return create_job(params, payload)
end

local function maybe_start_job(params, job, auto_start)
	if auto_start ~= true then
		return nil, 'auto_start_disabled'
	end
	if not job or job.state ~= 'created' then
		return nil, job and ('job_not_created:' .. tostring(job.state)) or 'job_missing'
	end

	local result, err = transition(params.jobs, {
		kind = 'start_job',
		generation = params.generation,
		job_id = job.job_id,
		phase = 'stage',
		reason = 'bundled_auto_start',
	})
	if not result then return nil, err or 'bundled_start_job_failed' end
	if result.status ~= 'persisted' then
		return nil, result.reason or 'bundled_start_job_rejected'
	end
	return result, nil
end

function M.run(scope, params)
	params = params or {}
	if params.jobs and type(params.jobs.ready_op) == 'function' then
		local ok_ready, ready_err = fibers.perform(params.jobs:ready_op())
		if ok_ready ~= true then error(ready_err or 'job_runtime_not_ready', 0) end
	end
	local spec = assert(params.spec, 'bundled_apply spec required')
	local desired = assert(params.desired, 'bundled_apply desired required')
	local payload = create_payload(spec, desired)
	if type(payload.artifact_ref) ~= 'string' or payload.artifact_ref == '' then
		error('bundled_artifact_ref_required', 0)
	end

	local created, cerr = create_or_reuse_job(params, payload)
	if not created then error(cerr or 'bundled_create_failed', 0) end

	local job = created.job or (created.job_id and params.jobs:get(created.job_id))
	local start_result, start_err = maybe_start_job(params, job, payload.auto_start)

	return {
		tag = 'bundled_apply_result',
		component = spec.component,
		job_id = payload.job_id,
		artifact_ref = payload.artifact_ref,
		create = created,
		start = start_result,
		start_skipped = start_result == nil and start_err or nil,
	}
end

function M.start(spec)
	spec = spec or {}
	return scoped_work.start {
		lifetime_scope = assert(spec.lifetime_scope, 'lifetime_scope required'),
		reaper_scope   = spec.reaper_scope or spec.lifetime_scope,
		report_scope   = assert(spec.report_scope or spec.lifetime_scope, 'report_scope required'),

		identity = {
			kind       = 'bundled_apply_done',
			service_id = spec.service_id,
			generation = spec.generation,
			component  = spec.component,
		},

		run = function (scope)
			return M.run(scope, spec)
		end,

		report = function (ev)
			if not spec.done_tx then return true, nil end
			return queue.try_admit_required(
				spec.done_tx,
				ev,
				'update_bundled_apply_completion_report_failed'
			)
		end,
	}
end

return M
