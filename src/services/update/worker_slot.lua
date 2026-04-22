-- services/update/worker_slot.lua
--
-- Single active-worker slot for the update service.
--
-- Responsibilities:
--   * ensure only one worker scope is active at a time
--   * own worker-scope creation
--   * expose join_op() for the current active worker only
--   * acquire/release the service-global job lock
--
-- Note:
--   join_op() delegates directly to the active worker scope. Given the current
--   fibres semantics, callers should treat it as a sharp tool.

local M = {}
local WorkerSlot = {}
WorkerSlot.__index = WorkerSlot

function M.new(ctx)
	return setmetatable({ ctx = ctx }, WorkerSlot)
end

function WorkerSlot:current()
	return self.ctx.state.active_job
end

function WorkerSlot:is_idle()
	return self.ctx.state.active_job == nil
end

function WorkerSlot:join_op()
	local active = self:current()
	if not active then return nil end

	return active.scope:join_op():wrap(function(st, _report, primary)
		return {
			job_id = active.job_id,
			st = st,
			primary = primary,
		}
	end)
end

function WorkerSlot:spawn(job, mode, fn)
	local ctx = self.ctx
	local child, err = ctx.service_scope:child()
	if not child then return nil, err end

	ctx.model.acquire_lock(ctx.state, job, ctx.now(), ctx.service_run_id)
	local ok, save_err = ctx.store_sync.save_job(ctx.repo, job)
	if not ok then ctx.on_store_error(job.job_id, save_err) end

	local spawned, spawn_err = child:spawn(fn)
	if not spawned then
		ctx.model.release_lock(ctx.state, job, ctx.now(), ctx.service_run_id)
		local ok2, err2 = ctx.store_sync.save_job(ctx.repo, job)
		if not ok2 then ctx.on_store_error(job.job_id, err2) end
		return nil, spawn_err
	end

	ctx.model.set_active_job(ctx.state, {
		job_id = job.job_id,
		scope = child,
		component = job.component,
		started_at = ctx.now(),
		mode = mode,
	})
	ctx.changed:signal()
	return true, nil
end

function WorkerSlot:release(job_id)
	local ctx = self.ctx
	local job = ctx.state.store.jobs[job_id]

	ctx.model.release_lock(ctx.state, job, ctx.now(), ctx.service_run_id)
	if ctx.state.active_job and ctx.state.active_job.job_id == job_id then
		ctx.model.clear_active_job(ctx.state)
	end

	if job then
		local ok, err = ctx.store_sync.save_job(ctx.repo, job)
		if not ok then ctx.on_store_error(job_id, err) end
	end

	ctx.changed:signal()
end

return M
