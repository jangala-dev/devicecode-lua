-- services/update/manager.lua
--
-- Generation-local manager request router.
--
-- This module owns cheap manager request routing and admission into scoped
-- request work. Blocking request bodies live in manager_requests.lua.

local fibers          = require 'fibers'
local scoped_work     = require 'devicecode.support.scoped_work'
local queue           = require 'devicecode.support.queue'
local request_owner   = require 'devicecode.support.request_owner'
local model_mod       = require 'services.update.model'
local manager_requests = require 'services.update.manager_requests'

local M = {}

local ok_uuid, uuid = pcall(require, 'uuid')

local function copy(v)
	return model_mod.deep_copy(v)
end

local function new_id(prefix)
	if ok_uuid and uuid and type(uuid.new) == 'function' then
		return tostring(uuid.new())
	end
	return (prefix or 'id') .. '-' .. tostring(math.floor((fibers.now() or 0) * 1000000)) .. '-' .. tostring(math.random(1, 1000000))
end

local function fail_request(req, reason)
	local owner = request_owner.new(req)
	local ok, err = owner:fail_once(reason)
	if ok ~= true then error(err or tostring(reason or 'request_failed'), 0) end
end

local function reply_request(req, value, label)
	local owner = request_owner.new(req)
	local ok, err = owner:reply_once(value)
	if ok ~= true then error(err or label or 'manager_reply_failed', 0) end
end

local function manager_payload(req)
	return req and req.payload or nil
end

local function normalise_method(method)
	method = tostring(method or 'status')
	return method:gsub('-', '_')
end

function M.method(req)
	local payload = manager_payload(req)
	local method = req and req._update_method or 'status'
	return normalise_method(method), payload
end

local function start_scoped_request(ctx, req, method, runner)
	local request_id = new_id('req')
	local owner = request_owner.new(req)
	local handle, err = scoped_work.start {
		lifetime_scope = ctx.request_root,
		reaper_scope   = ctx.request_root,
		report_scope   = ctx.scope,

		identity = {
			kind       = 'manager_request_done',
			service_id = ctx.service_id,
			generation = ctx.generation,
			method     = method,
			request_id = request_id,
		},

		setup = function (scope)
			scope:finally(function (_, status, primary)
				if not owner:done() then
					if status == 'ok' then
						owner:finalise_unresolved(primary or 'request_scope_closed')
					else
						owner:finalise_unresolved(primary or status or 'request_cancelled')
					end
				end
			end)
			return {
				request_owner = owner,
				cancel_owned_now = function (reason)
					owner:abandon_unresolved(reason or 'caller_abandoned')
					return true
				end,
			}
		end,

		cancel_op = owner:caller_cancel_op(),

		run = function (work_scope, setup)
			return runner(work_scope, setup and setup.request_owner or owner)
		end,

		report = function (ev)
			return queue.try_admit_required(
				ctx.done_tx,
				ev,
				'update_manager_request_completion_report_failed'
			)
		end,
	}

	if not handle then
		owner:fail_once(err or 'request_start_failed')
		return nil, err
	end

	ctx.manager_work[request_id] = handle
	return handle, nil
end

local function handle_status(ctx, req)
	reply_request(req, {
		ok = true,
		snapshot = copy(ctx.snapshot or {}),
	}, 'status_reply_failed')
end

local function handle_list(ctx, req)
	reply_request(req, { ok = true, jobs = ctx.jobs:list() }, 'list_reply_failed')
end

local function handle_get(ctx, req, payload)
	local owner = request_owner.new(req)
	local job_id = type(payload) == 'table' and payload.job_id or nil
	local job = job_id and ctx.jobs:get(job_id) or nil
	if not job then
		local ok, err = owner:fail_once('not_found')
		if ok ~= true then error(err or 'get_failure_reply_failed', 0) end
		return
	end
	local ok, err = owner:reply_once({ ok = true, job = job })
	if ok ~= true then error(err or 'get_reply_failed', 0) end
end


local function jobs_ready(ctx)
	return ctx.jobs == nil or type(ctx.jobs.ready) ~= 'function' or ctx.jobs:ready() == true
end

local function reject_if_jobs_not_ready(ctx, req)
	if jobs_ready(ctx) then return false end
	fail_request(req, 'job_runtime_not_ready')
	return true
end

local function is_ingest_method(method)
	return method == 'ingest_create'
		or method == 'ingest_append'
		or method == 'ingest_commit'
		or method == 'ingest_abort'
end

local function handle_create(ctx, req)
	if reject_if_jobs_not_ready(ctx, req) then return end
	return start_scoped_request(ctx, req, 'create_job', function (work_scope, owner)
		return manager_requests.create_job(work_scope, {
			request_owner = owner,
			request = req,
			jobs = ctx.jobs,
			config = ctx.config,
			generation = ctx.generation,
			artifact_store = ctx.artifact_store,
		})
	end)
end

local function handle_start(ctx, req, payload)
	if reject_if_jobs_not_ready(ctx, req) then return end
	payload = type(payload) == 'table' and payload or {}
	local job_id = payload.job_id
	local job = ctx.jobs:get(job_id)
	local phase = payload._forced_phase or payload.phase or (job and job.state == 'awaiting_commit' and 'commit' or 'stage')

	-- Cheap rejection is allowed, but durable admission is owned by job_runtime.
	-- The request scope persists active intent; the service-owned active launcher
	-- later starts work from that durable intent.
	if not job then
		fail_request(req, 'not_found')
		return
	end
	if ctx.active ~= nil then
		local active = ctx.active
		local same_job_commit_release_lag = active
			and active.job_id == job_id
			and phase == 'commit'
			and job
			and job.state == 'awaiting_commit'
		if active ~= nil and not same_job_commit_release_lag then
			fail_request(req, 'slot_busy')
			return
		end
	end

	return start_scoped_request(ctx, req, phase == 'commit' and 'commit_job' or 'start_job', function (work_scope, owner)
		return manager_requests.start_job(work_scope, {
			request_owner = owner,
			request = req,
			jobs = ctx.jobs,
			job_id = job_id,
			generation = ctx.generation,
			phase = phase,
		})
	end)
end

local function handle_patch(ctx, req, payload, method, patch)
	if reject_if_jobs_not_ready(ctx, req) then return end
	payload = type(payload) == 'table' and payload or {}
	local job_id = payload.job_id
	if type(job_id) ~= 'string' or job_id == '' then
		fail_request(req, 'job_id_required')
		return
	end
	return start_scoped_request(ctx, req, method, function (work_scope, owner)
		return manager_requests.persist_job_state(work_scope, {
			request_owner = owner,
			request = req,
			jobs = ctx.jobs,
			job_id = job_id,
			generation = ctx.generation,
			method = method,
			patch = patch(payload),
		})
	end)
end

local function handle_cancel(ctx, req, payload)
	return handle_patch(ctx, req, payload, 'cancel_job', function (p)
		return {
			state = 'cancelled',
			next_step = nil,
			error = p.reason or 'cancelled',
		}
	end)
end

local function handle_retry(ctx, req, payload)
	return handle_patch(ctx, req, payload, 'retry_job', function (_)
		return {
			state = 'created',
			next_step = 'start',
			error = nil,
			active = nil,
			active_token = nil,
			active_intent = nil,
		}
	end)
end

local function handle_discard(ctx, req, payload)
	if reject_if_jobs_not_ready(ctx, req) then return end
	payload = type(payload) == 'table' and payload or {}
	local job_id = payload.job_id
	if type(job_id) ~= 'string' or job_id == '' then
		fail_request(req, 'job_id_required')
		return
	end
	return start_scoped_request(ctx, req, 'discard_job', function (work_scope, owner)
		return manager_requests.discard_job(work_scope, {
			request_owner = owner,
			request = req,
			jobs = ctx.jobs,
			job_id = job_id,
			generation = ctx.generation,
		})
	end)
end

function M.handle_request(ctx, req)
	local method, payload = M.method(req)

	if is_ingest_method(method) then
		if ctx.ingest and type(ctx.ingest.submit) == 'function' then
			local ok, err = ctx.ingest:submit(req)
			if ok ~= true then fail_request(req, err or 'ingest_admission_failed') end
			return
		end
		fail_request(req, 'ingest_unavailable')
		return
	end

	if method == 'status' then handle_status(ctx, req); return end
	if method == 'list_jobs' then handle_list(ctx, req); return end
	if method == 'get_job' then handle_get(ctx, req, payload); return end
	if method == 'create_job' then handle_create(ctx, req); return end
	if method == 'start_job' then handle_start(ctx, req, payload); return end
	if method == 'commit_job' then
		payload = type(payload) == 'table' and payload or {}
		payload._forced_phase = 'commit'
		handle_start(ctx, req, payload)
		return
	end
	if method == 'cancel_job' then handle_cancel(ctx, req, payload); return end
	if method == 'retry_job' then handle_retry(ctx, req, payload); return end
	if method == 'discard_job' then handle_discard(ctx, req, payload); return end

	fail_request(req, 'unsupported_update_method: ' .. tostring(method))
end

function M.handle_done(ctx, ev)
	if ev.service_id ~= ctx.service_id then return false, 'stale_service' end
	if ev.generation ~= ctx.generation then return false, 'stale_generation' end

	ctx.manager_work[ev.request_id] = nil

	-- Durable job state is owned by job_runtime.  Manager completions are
	-- observations only; update the generation projection from the runtime
	-- snapshot if the request completed successfully or failed after a state
	-- transition attempt.
	return true, nil
end

M.fail_request = fail_request

return M
