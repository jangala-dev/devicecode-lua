-- services/update/runtime.lua
--
-- Runtime orchestration around the single active worker slot.
--
-- Responsibilities:
--   * spawn stage/commit/reconcile runners
--   * interpret runner events into model transitions
--   * react to active worker completion
--   * resume adopted awaiting-return jobs
--
-- This module owns orchestration and state transition wiring, not backend
-- transport or retained publication formatting.

local worker_slot_mod = require 'services.update.worker_slot'

local M = {}
local Runtime = {}
Runtime.__index = Runtime

function M.new(ctx)
	return setmetatable({
		ctx = ctx,
		slot = worker_slot_mod.new(ctx),
	}, Runtime)
end

function Runtime:release_active(job_id)
	return self.slot:release(job_id)
end

function Runtime:spawn_runner(mode, job)
	local ctx = self.ctx
	local backend = ctx.state.backends[job.component]
	if not backend then return nil, 'backend_missing' end

	local cfg_reconcile = ctx.state.cfg.reconcile
	local snapshot = ctx.copy_job(job)

	return self.slot:spawn(job, mode, function()
		if mode == 'stage' then
			return ctx.runner.run_stage(ctx.conn, snapshot, backend, ctx.runner_tx, ctx)
		elseif mode == 'commit' then
			return ctx.runner.run_commit(ctx.conn, snapshot, backend, ctx.runner_tx, cfg_reconcile, ctx)
		else
			return ctx.runner.run_reconcile(ctx.conn, snapshot, backend, ctx.runner_tx, cfg_reconcile, ctx.observer, ctx)
		end
	end)
end

function Runtime:active_join_op()
	return self.slot:join_op()
end

function Runtime:spawn_reconcile(job)
	local ctx = self.ctx

	ctx.store_sync.flush_jobs(ctx.repo, ctx.state, ctx.on_store_error)

	local ok, err = self:spawn_runner('reconcile', job)
	if not ok then
		ctx.patch_job(job, {
			state = 'failed',
			stage = 'failed',
			error = tostring(err or 'reconcile_spawn_failed'),
			next_step = nil,
		})
		return nil, err
	end

	return true, nil
end

function Runtime:on_changed_tick()
	local ctx = self.ctx

	ctx.publisher:flush_publications()

	-- Adopted awaiting-return jobs are resumed opportunistically once the slot
	-- is idle and the changed tick runs.
	local resumable = ctx.model.select_resumable_job(ctx.state)
	if resumable then
		local ok, err = self:spawn_reconcile(resumable)
		if not ok then
			ctx.svc:obs_log('warn', {
				what = 'adopted_job_resume_failed',
				job_id = resumable.job_id,
				err = tostring(err),
			})
		end
	end
end

function Runtime:handle_runner_event(ev)
	local ctx = self.ctx
	if not (ev and ev.job_id) then return end

	local job = ctx.state.store.jobs[ev.job_id]
	if not job then return end

	if ev.tag == 'failed' then
		ctx.patch_job(job, {
			state = 'failed',
			stage = 'failed',
			error = tostring(ev.err or 'failed'),
			next_step = nil,
		})
		ctx.release_artifact_if_present(job)

	elseif ev.tag == 'staged' then
		if ev.pre_commit_boot_id ~= nil then
			job.pre_commit_boot_id = ev.pre_commit_boot_id
		end
		ctx.patch_job(job, {
			state = 'awaiting_commit',
			stage = 'staged_on_mcu',
			next_step = 'commit',
			result = ev.staged,
			staged_meta = ev.staged,
			error = nil,
		})
		if type(ev.staged) == 'table' and ev.staged.artifact_retention == 'release' then
			ctx.release_artifact_if_present(job)
		end

	elseif ev.tag == 'commit_started' then
		ctx.enter_awaiting_return(job, 'awaiting_member_return', ev.result)

	elseif ev.tag == 'reconciled_success' then
		ctx.patch_job(job, {
			state = 'succeeded',
			stage = 'succeeded',
			result = ev.result,
			error = nil,
			next_step = nil,
		})
		if ctx.on_job_succeeded then
			ctx.on_job_succeeded(job, ev.result)
		end
		ctx.release_artifact_if_present(job)

	elseif ev.tag == 'reconciled_failure' then
		ctx.patch_job(job, {
			state = 'failed',
			stage = 'failed',
			result = ev.result,
			error = tostring(ev.err or 'reconcile_failed'),
			next_step = nil,
		})
		ctx.release_artifact_if_present(job)

	elseif ev.tag == 'reconcile_progress' then
		ctx.patch_job(job, {
			state = 'awaiting_return',
			stage = 'verifying_postboot',
			result = ev.result,
			error = nil,
			next_step = 'reconcile',
		}, {
			no_save = true,
			no_signal = true,
		})
		ctx.publisher:publish_job_only(job)

	elseif ev.tag == 'timed_out' then
		ctx.patch_job(job, {
			state = 'timed_out',
			stage = 'timed_out',
			error = tostring(ev.err or 'timeout'),
			next_step = nil,
		})
		ctx.release_artifact_if_present(job)
	end
end

function Runtime:handle_active_join(ev)
	local ctx = self.ctx
	local current_active = self.slot:current()

	self:release_active(ev.job_id)

	local job = ctx.state.store.jobs[ev.job_id]
	if not (ev and job and current_active and current_active.job_id == ev.job_id) then
		return
	end

	if ev.st == 'failed' and not ctx.model.is_terminal(job.state) then
		ctx.patch_job(job, {
			state = 'failed',
			stage = 'failed',
			error = tostring(ev.primary or 'worker_failed'),
			next_step = nil,
		})
		return
	end

	if ev.st == 'cancelled' and not ctx.model.is_terminal(job.state) then
		ctx.patch_job(job, {
			state = 'cancelled',
			stage = 'failed',
			error = tostring(ev.primary or 'worker_cancelled'),
			next_step = nil,
		})
		return
	end

	if ev.st ~= 'ok' then
		return
	end

	if job.state == 'awaiting_return' and job.next_step == 'reconcile' then
		self:spawn_reconcile(job)
		return
	end

	-- Auto-commit is triggered only once the previous worker has completed
	-- cleanly and the slot has been released.
	if job.state == 'awaiting_commit' and job.auto_commit then
		local ok, err = ctx.model.can_activate(ctx.state, job)
		if ok then
			ctx.enter_awaiting_return(job, 'commit_sent')
			local wok, werr = self:spawn_runner('commit', job)
			if not wok then
				ctx.patch_job(job, {
					state = 'failed',
					stage = 'failed',
					error = tostring(werr or 'commit_spawn_failed'),
					next_step = nil,
				})
			end
		else
			ctx.patch_job(job, {
				state = 'failed',
				stage = 'failed',
				error = tostring(err or 'auto_commit_blocked'),
				next_step = nil,
			})
		end
	end
end

return M
