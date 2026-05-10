-- services/update/manager_requests.lua
--
-- Scoped manager-request worker bodies.
--
-- These functions own caller-visible request resolution.  Durable job mutation
-- is requested from the service-owned job_runtime; this module does not call the
-- job store directly and does not mutate the authoritative repository.

local fibers        = require 'fibers'
local request_owner = require 'devicecode.support.request_owner'
local model_mod     = require 'services.update.model'
local resolver      = require 'services.update.artifacts.resolver'
local lifetime      = require 'services.update.artifacts.lifetime'

local M = {}


local function copy(v)
	return model_mod.deep_copy(v)
end

local function payload_of(req)
	return type(req) == 'table' and type(req.payload) == 'table' and req.payload or {}
end

local function install_owner(scope, req, reason)
	local owner = request_owner.new(req)
	scope:finally(function (_, status, primary)
		if status == 'failed' then
			owner:finalise_unresolved(primary or reason or 'request_failed')
		elseif status == 'cancelled' then
			owner:finalise_unresolved(primary or reason or 'request_cancelled')
		else
			owner:finalise_unresolved(reason or primary or status or 'request_scope_closed')
		end
	end)
	return owner
end

local function reply_or_fail(owner, value, err, label)
	local ok, rerr
	if err == nil then
		ok, rerr = owner:reply_once(value)
	else
		ok, rerr = owner:fail_once(err)
	end
	if ok ~= true then
		error(rerr or (label or 'manager_request_reply_failed'), 0)
	end
end

local function assert_known_component(cfg, component)
	local comps = cfg and cfg.components or nil
	if comps and next(comps) ~= nil and comps[component] == nil then
		return nil, 'unknown_component'
	end
	return true, nil
end

local function run_artifact_check(check, artifact, payload)
	if check == nil then return true, nil end
	if type(check) ~= 'function' then return nil, 'artifact_preflight must be a function' end
	local ok, err = check(artifact, payload)
	if ok == nil or ok == false then return nil, err or 'artifact_preflight_failed' end
	return true, nil
end

local function maybe_resolve_create_artifact(scope, params, payload, component)
	local source = payload.artifact_source or payload.source
	local artifact = payload.artifact

	-- A plain artifact_ref is already a durable reference owned outside this
	-- request scope. Do not wrap it in temporary cleanup ownership.
	if source == nil and artifact == nil then
		return nil, nil
	end

	-- A direct artifact table without an immediate cleanup path is treated as an
	-- already-durable reference. Temporary imports from an artifact store must
	-- provide immediate cleanup and are validated by resolver/lifetime below.
	if source == nil and artifact ~= nil and not lifetime.has_immediate_cleanup(artifact) then
		local snap = copy(artifact)
		payload.artifact = snap
		payload.artifact_ref = payload.artifact_ref or snap.ref or snap.id
		return nil, nil
	end

	local resolved = resolver.resolve_worker(scope, {
		store = params.artifact_store,
		source = source,
		artifact = artifact,
		component = component,
		metadata = payload.metadata or payload.meta,
		cleanup_reason = 'create_job_scope_closed',
	})

	local ok_check, check_err = run_artifact_check(params.artifact_preflight or params.preflight, resolved.artifact, payload)
	if ok_check ~= true then
		return nil, check_err
	end

	local snap = copy(resolved.artifact)
	payload.artifact = snap
	payload.artifact_ref = payload.artifact_ref or snap.ref or snap.id

	return resolved.owned, nil
end

local function transition(jobs, cmd)
	if not jobs or type(jobs.admit_transition) ~= 'function' then
		return nil, 'job_runtime_unavailable'
	end
	local handle, admit_err = jobs:admit_transition(cmd)
	if not handle then
		return nil, admit_err or 'job_transition_admission_failed'
	end
	return fibers.perform(handle:outcome_op())
end

function M.create_job(scope, params)
	params = params or {}
	local req = assert(params.request, 'create_job: request required')
	local owner = install_owner(scope, req, 'create_job_cancelled')
	local payload = payload_of(req)
	local component = payload.component

	if type(component) ~= 'string' or component == '' then
		reply_or_fail(owner, nil, 'component_required', 'component_required_reply_failed')
		return {
			tag = 'manager_request_rejected',
			method = 'create_job',
			reason = 'component_required',
		}
	end

	local ok_component, component_err = assert_known_component(params.config, component)
	if ok_component ~= true then
		reply_or_fail(owner, nil, component_err, 'unknown_component_reply_failed')
		return {
			tag = 'manager_request_rejected',
			method = 'create_job',
			reason = component_err,
		}
	end

	local artifact_owner, artifact_err = maybe_resolve_create_artifact(scope, params, payload, component)
	if artifact_err ~= nil then
		reply_or_fail(owner, nil, artifact_err, 'artifact_preflight_reply_failed')
		return {
			tag = 'manager_request_rejected',
			method = 'create_job',
			reason = artifact_err,
		}
	end

	local result, err = transition(params.jobs, {
		kind = 'create_job',
		generation = params.generation,
		payload = payload,
		reason = 'create_job',
	})
	if not result or result.status ~= 'persisted' then
		local reason = err or (result and result.reason) or 'create_job_failed'
		reply_or_fail(owner, nil, reason, 'create_job_reply_failed')
		if result and result.status == 'rejected' then
			return { tag = 'manager_request_rejected', method = 'create_job', reason = reason }
		end
		error(reason, 0)
	end

	if artifact_owner ~= nil then
		local ok_transfer, transfer_err = artifact_owner:handoff(function () return true end)
		if ok_transfer == nil then
			reply_or_fail(owner, nil, transfer_err or 'artifact_ownership_transfer_failed', 'create_job_reply_failed')
			error(transfer_err or 'artifact_ownership_transfer_failed', 0)
		end
	end

	reply_or_fail(owner, { ok = true, job = result.job }, nil, 'create_job_reply_failed')
	return result
end

function M.start_job(scope, params)
	params = params or {}
	local req = assert(params.request, 'start_job: request required')
	local owner = install_owner(scope, req, 'start_job_cancelled')
	local phase = params.phase or 'stage'
	local job_id = params.job_id or (params.job and params.job.job_id)

	local result, err = transition(params.jobs, {
		kind = 'start_job',
		generation = params.generation,
		job_id = job_id,
		phase = phase,
		request_id = params.request_id,
		reason = phase == 'commit' and 'start_commit' or 'start_stage',
	})

	if not result or result.status ~= 'persisted' then
		local reason = err or (result and result.reason) or 'job_transition_failed'
		reply_or_fail(owner, nil, reason, 'start_job_persist_reply_failed')
		if result and result.status == 'rejected' then
			return { tag = 'manager_request_rejected', method = phase == 'commit' and 'commit_job' or 'start_job', reason = reason }
		end
		error(reason, 0)
	end

	-- Durable active intent now exists.  The service-owned active launcher, not
	-- this request scope, will start active execution from job_runtime state.
	reply_or_fail(owner, {
		ok = true,
		accepted = true,
		job = result.job,
		phase = result.phase,
		token = result.token,
	}, nil, 'start_job_reply_failed')

	return result
end

function M.persist_job_state(scope, params)
	params = params or {}
	local req = assert(params.request, 'persist_job_state: request required')
	local owner = install_owner(scope, req, tostring(params.method or 'request') .. '_cancelled')

	local result, err = transition(params.jobs, {
		kind = 'patch_job',
		generation = params.generation,
		job_id = params.job_id or (params.job and params.job.job_id),
		patch = params.patch or params.job or {},
		reason = params.method or 'job_request',
	})
	if not result or result.status ~= 'persisted' then
		local reason = err or (result and result.reason) or 'job_persist_failed'
		reply_or_fail(owner, nil, reason, 'persist_job_state_reply_failed')
		if result and result.status == 'rejected' then
			return { tag = 'manager_request_rejected', method = params.method or 'job_request', reason = reason }
		end
		error(reason, 0)
	end

	reply_or_fail(owner, {
		ok = true,
		job = result.job,
		accepted = true,
	}, nil, 'persist_job_state_reply_failed')

	return result
end


function M.discard_job(scope, params)
	params = params or {}
	local req = assert(params.request, 'discard_job: request required')
	local owner = install_owner(scope, req, 'discard_job_cancelled')

	local result, err = transition(params.jobs, {
		kind = 'discard_job',
		generation = params.generation,
		job_id = params.job_id or (params.job and params.job.job_id),
		reason = params.method or 'discard_job',
	})
	if not result or result.status ~= 'persisted' then
		local reason = err or (result and result.reason) or 'discard_job_failed'
		reply_or_fail(owner, nil, reason, 'discard_job_reply_failed')
		if result and result.status == 'rejected' then
			return { tag = 'manager_request_rejected', method = 'discard_job', reason = reason }
		end
		error(reason, 0)
	end

	reply_or_fail(owner, {
		ok = true,
		job = result.job,
		accepted = true,
		discarded = true,
	}, nil, 'discard_job_reply_failed')

	return result
end

return M
