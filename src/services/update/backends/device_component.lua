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

	return self._conn:call_op(
		device_topics.component_cap_rpc(job.component, method),
		payload or {},
		{ timeout = timeout }
	):wrap(normalise_action_reply)
end

local function base_payload(job, ctx)
	return {
		component = job.component,
		target = job.component,
		job_id = job.job_id,
		artifact_ref = job.artifact_ref,
		artifact_id = job.artifact_ref,
		expected_image_id = job.expected_image_id,
		options = model.deep_copy(job.options or {}),
		metadata = model.deep_copy(job.metadata or {}),
		commit_token = ctx and ctx.commit_token or nil,
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
		call_timeout(self, ctx, 'timeout_stage', 300.0)
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

function Backend:evaluate_reconcile(job, snapshot, _ctx)
	local observed
	if type(snapshot) == 'table'
		and type(snapshot.components) == 'table'
		and type(job) == 'table'
	then
		observed = snapshot.components[job.component]
	end

	return {
		done = true,
		ok = true,
		tag = 'reconciled_success',
		result = {
			component = job and job.component or nil,
			observed = observed,
		},
	}
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
