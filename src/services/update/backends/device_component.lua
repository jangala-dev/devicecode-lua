-- services/update/backends/device_component.lua
--
-- Generic update backend that drives Device component actions. It keeps Update
-- policy in the update service while delegating target-specific prepare, stage,
-- and commit work to cap/component/<id>/rpc/*.

local op = require 'fibers.op'

local device_topics = require 'services.device.topics'
local model         = require 'services.update.model'

local M = {}

local Backend = {}
Backend.__index = Backend

local function call_timeout(self, ctx, key, fallback)
	if ctx and type(ctx.timeout) == 'number' then return ctx.timeout end
	if type(self[key]) == 'number' then return self[key] end
	return fallback
end

local function normalise_action_reply(reply, err)
	if reply == nil then return nil, err end
	if type(reply) == 'table' and reply.ok == false then
		return nil, reply.err or reply.error or reply.reason or 'component_action_failed'
	end
	return reply, nil
end

local function component_call_op(self, job, method, payload, timeout)
	if type(self._conn) ~= 'table' or type(self._conn.call_op) ~= 'function' then
		return op.always(nil, 'update backend connection unavailable')
	end
	if type(job) ~= 'table' or type(job.component) ~= 'string' or job.component == '' then
		return op.always(nil, 'update backend job component required')
	end

	local topic = device_topics.component_cap_rpc(job.component, method)
	return self._conn:call_op(
		topic,
		payload or {},
		{ timeout = timeout }
	):wrap(function (reply, err)
		local result, norm_err = normalise_action_reply(reply, err)
		if result == nil then
			return nil, norm_err
		end
		return result, nil
	end)
end

local function base_payload(job, ctx)
	return {
		component = job.component,
		target = job.component,
		job_id = job.job_id,
		artifact_ref = job.artifact_ref,
		artifact_id = job.artifact_ref,
		expected_image_id = job.expected_image_id
			or (type(job.metadata) == 'table' and job.metadata.image_id or nil),
		options = model.deep_copy(job.options or {}),
		metadata = model.deep_copy(job.metadata or {}),
		commit_token = ctx and ctx.commit_token or nil,
	}
end

local function image_id_for(job)
	if type(job) ~= 'table' then return nil end
	if job.expected_image_id ~= nil then return job.expected_image_id end
	local metadata = job.metadata
	if type(metadata) == 'table' then return metadata.image_id end
	return nil
end

local function component_state_for(job, ctx)
	if type(ctx) ~= 'table' then return nil end
	if type(ctx.component_state) == 'table' then return ctx.component_state end
	local snapshot = ctx.snapshot
	if type(job) ~= 'table' or type(job.component) ~= 'string' then return nil end
	if type(snapshot) ~= 'table' then return nil end
	if type(snapshot.components) == 'table' then return snapshot.components[job.component] end
	if type(snapshot.by_id) == 'table' then
		local rec = snapshot.by_id[job.component]
		if type(rec) == 'table' then return rec.state or rec end
	end
	return nil
end

local function success_phase(phase)
	return phase == nil or phase == 'running' or phase == 'idle' or phase == 'ready'
end

local function reconcile_payload(component_state, job)
	job = type(job) == 'table' and job or {}

	local sw = type(component_state) == 'table' and component_state.software or nil
	local upd = type(component_state) == 'table' and component_state.updater or nil
	local image_id = type(sw) == 'table' and sw.image_id or nil
	local version = type(sw) == 'table' and sw.version or nil
	local build = type(sw) == 'table' and sw.build or nil
	local boot_id = type(sw) == 'table' and sw.boot_id or nil
	local phase = type(upd) == 'table' and upd.state or nil
	local last_error = type(upd) == 'table' and upd.last_error or nil
	local expected_image_id = image_id_for(job)

	return {
		expected_image_id = expected_image_id,
		image_id = image_id,
		version = version,
		build = build,
		boot_id = boot_id,
		pre_commit_boot_id = job.pre_commit_boot_id,
		phase = phase,
		last_error = last_error,
		raw = component_state,
	}
end

function M.evaluate_component_state(component_state, job)
	local out = reconcile_payload(component_state, job)

	if out.phase == 'failed' or out.phase == 'rollback_detected' then
		out.done = true
		out.success = false
		out.error = tostring(out.last_error or out.phase)
		return out
	end

	if out.expected_image_id == nil or out.expected_image_id == '' then
		out.done = true
		out.success = true
		return out
	end

	if out.image_id == out.expected_image_id then
		if success_phase(out.phase) then
			out.done = true
			out.success = true
			return out
		end
	end

	out.done = false
	return out
end

local function wrap_reconcile_result(job, observed, result)
	result = result or {}
	result.component = job and job.component or nil
	result.observed = observed

	if result.done ~= true then
		return {
			done = false,
			result = result,
			observed = observed,
		}
	end

	if result.success == false then
		return {
			done = true,
			ok = false,
			tag = 'reconciled_failure',
			reason = result.error or 'reconcile_failed',
			error = result.error or 'reconcile_failed',
			result = result,
			observed = observed,
		}
	end

	return {
		done = true,
		ok = true,
		tag = 'reconciled_success',
		result = result,
		observed = observed,
	}
end

function Backend:prepare_op(job, ctx)
	return component_call_op(
		self,
		job,
		'prepare-update',
		base_payload(job, ctx),
		call_timeout(self, ctx, 'timeout_prepare', 10.0)
	)
end

function Backend:stage_op(job, ctx)
	return component_call_op(
		self,
		job,
		'stage-update',
		base_payload(job, ctx),
		call_timeout(self, ctx, 'timeout_stage', 900.0)
	)
end

function Backend:commit_capabilities()
	return { policy = 'idempotent_by_token' }
end

function Backend:commit_op(job, ctx)
	return component_call_op(
		self,
		job,
		'commit-update',
		base_payload(job, ctx),
		call_timeout(self, ctx, 'timeout_commit', 60.0)
	)
end

function Backend:evaluate_reconcile(job, snapshot, ctx)
	local observed = component_state_for(job, {
		snapshot = snapshot,
	})

	return wrap_reconcile_result(job, observed, M.evaluate_component_state(observed, job))
end

function M.new(opts)
	opts = opts or {}
	return setmetatable({
		_conn = opts.conn,
		timeout_prepare = opts.timeout_prepare,
		timeout_stage = opts.timeout_stage,
		timeout_commit = opts.timeout_commit,
	}, Backend)
end

M.Backend = Backend

return M
