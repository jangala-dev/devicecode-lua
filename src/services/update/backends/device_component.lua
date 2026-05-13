-- services/update/backends/device_component.lua
--
-- Generic update backend that drives Device component actions. It keeps Update
-- policy in the update service while delegating target-specific prepare, stage,
-- and commit work to cap/component/<id>/rpc/*.

local fibers = require 'fibers'
local op     = require 'fibers.op'
local sleep  = require 'fibers.sleep'

local device_topics = require 'services.device.topics'
local model         = require 'services.update.model'

local M = {}

local DEFAULT_COMMIT_SETTLE_S = 0.5
local DEFAULT_STAGE_RETRY_DELAY_S = 3.0
local DEFAULT_STAGE_MAX_ATTEMPTS = 3

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

local function is_transient_stage_error(err)
	local s = tostring(err or '')
	return s == 'transfer_sender_frame_feed_closed'
		or s == 'session_closed'
		or s == 'new_peer_session'
		or s == 'link_not_ready'
		or s == 'no_session'
		or s:match('session_dropped') ~= nil
		or s:match('frame_feed_closed') ~= nil
end

local function retrying_stage_call_op(self, job, payload, timeout)
	local max_attempts = self.stage_max_attempts or DEFAULT_STAGE_MAX_ATTEMPTS
	local retry_delay = self.stage_retry_delay_s or DEFAULT_STAGE_RETRY_DELAY_S
	if max_attempts <= 1 then
		return component_call_op(self, job, 'stage-update', payload, timeout)
	end

	return fibers.run_scope_op(function ()
		local last_err
		for attempt = 1, max_attempts do
			local reply, err = fibers.perform(component_call_op(self, job, 'stage-update', payload, timeout))
			if reply ~= nil then return reply, nil end
			last_err = err or 'stage_update_failed'
			if attempt >= max_attempts or not is_transient_stage_error(last_err) then
				return nil, last_err
			end
			fibers.perform(sleep.sleep_op(retry_delay))
		end
		return nil, last_err or 'stage_update_failed'
	end):wrap(function (st, rep, reply, err)
		if st ~= 'ok' then
			return nil, tostring(err or rep or st)
		end
		return reply, err
	end)
end

local function commit_settle_s(self, ctx)
	if ctx and type(ctx.commit_settle_s) == 'number' then return ctx.commit_settle_s end
	if type(self.commit_settle_s) == 'number' then return self.commit_settle_s end
	return DEFAULT_COMMIT_SETTLE_S
end

local function settled_component_call_op(self, job, method, payload, timeout, settle_s)
	if settle_s == nil or settle_s <= 0 then
		return component_call_op(self, job, method, payload, timeout)
	end

	return fibers.run_scope_op(function ()
		fibers.perform(sleep.sleep_op(settle_s))
		return fibers.perform(component_call_op(self, job, method, payload, timeout))
	end):wrap(function (st, rep, reply, err)
		if st ~= 'ok' then
			return nil, tostring(err or rep or st)
		end
		return reply, err
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

local function legacy_streamed_commit_image_id(self, job, ctx, payload)
	if type(payload) ~= 'table' then return nil end
	local expected = payload.expected_image_id
	if type(expected) ~= 'string' or expected == '' then return nil end

	local metadata = type(job) == 'table' and job.metadata or nil
	if type(metadata) ~= 'table' or metadata.image_id ~= expected then return nil end
	local explicit = metadata.compat_commit_image_id
	if type(explicit) == 'string' and explicit ~= '' and explicit ~= expected then
		return explicit
	end

	local observed = component_state_for(job, ctx)
	local sw = type(observed) == 'table' and observed.software or nil
	local upd = type(observed) == 'table' and observed.updater or nil
	if type(upd) ~= 'table' or upd.state ~= 'staged' then return nil end
	if upd.pending_image_id ~= expected then return nil end

	local staged = upd.staged_image_id
	if type(staged) ~= 'string' or staged == '' or staged == expected then return nil end

	local running = type(sw) == 'table' and sw.image_id or nil
	if type(running) == 'string' and running ~= '' and running ~= staged then return nil end

	return staged
end

local function commit_payload(self, job, ctx)
	local payload = base_payload(job, ctx)
	local commit_image_id = legacy_streamed_commit_image_id(self, job, ctx, payload)
	if commit_image_id ~= nil then
		payload.metadata = model.deep_copy(payload.metadata or {})
		payload.metadata.original_expected_image_id = payload.expected_image_id
		payload.metadata.compat_commit_expected_image_id = commit_image_id
		payload.expected_image_id = commit_image_id
	end
	return payload
end

local function success_phase(phase)
	return phase == nil or phase == 'running' or phase == 'idle' or phase == 'ready'
end

local function reconcile_payload(component_state, job, opts)
	job = type(job) == 'table' and job or {}
	opts = type(opts) == 'table' and opts or {}

	local sw = type(component_state) == 'table' and component_state.software or nil
	local upd = type(component_state) == 'table' and component_state.updater or nil
	local image_id = type(sw) == 'table' and sw.image_id or nil
	local version = type(sw) == 'table' and sw.version or nil
	local build = type(sw) == 'table' and sw.build or nil
	local boot_id = type(sw) == 'table' and sw.boot_id or nil
	local phase = type(upd) == 'table' and upd.state or nil
	local last_error = type(upd) == 'table' and upd.last_error or nil
	local expected_image_id = image_id_for(job)
	local boot_changed = (
		opts.require_boot_change == true
		and job.pre_commit_boot_id ~= nil
		and boot_id ~= nil
		and boot_id ~= job.pre_commit_boot_id
	)

	return {
		expected_image_id = expected_image_id,
		image_id = image_id,
		version = version,
		build = build,
		boot_id = boot_id,
		pre_commit_boot_id = job.pre_commit_boot_id,
		boot_changed = boot_changed,
		phase = phase,
		last_error = last_error,
		raw = component_state,
	}
end

function M.evaluate_component_state(component_state, job, opts)
	local out = reconcile_payload(component_state, job, opts)

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
		if out.boot_changed or success_phase(out.phase) then
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
	return retrying_stage_call_op(
		self,
		job,
		base_payload(job, ctx),
		call_timeout(self, ctx, 'timeout_stage', 900.0)
	)
end

function Backend:commit_capabilities()
	return { policy = 'idempotent_by_token' }
end

function Backend:commit_op(job, ctx)
	return settled_component_call_op(
		self,
		job,
		'commit-update',
		commit_payload(self, job, ctx),
		call_timeout(self, ctx, 'timeout_commit', 60.0),
		commit_settle_s(self, ctx)
	)
end

function Backend:evaluate_reconcile(job, snapshot, ctx)
	local observed = component_state_for(job, {
		snapshot = snapshot,
	})

	local opts = ctx or {}
	local metadata = type(job) == 'table' and job.metadata or nil
	if type(metadata) == 'table' and metadata.require_boot_change == true then
		opts = model.deep_copy(opts)
		opts.require_boot_change = true
	end

	return wrap_reconcile_result(job, observed, M.evaluate_component_state(observed, job, opts))
end

function M.new(opts)
	opts = opts or {}
	return setmetatable({
		_conn = opts.conn,
		timeout_prepare = opts.timeout_prepare,
		timeout_stage = opts.timeout_stage,
		timeout_commit = opts.timeout_commit,
		commit_settle_s = opts.commit_settle_s,
		stage_max_attempts = opts.stage_max_attempts,
		stage_retry_delay_s = opts.stage_retry_delay_s,
	}, Backend)
end

M.Backend = Backend

return M
