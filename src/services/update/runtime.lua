local safe = require 'coxpcall'

local M = {}
local Runtime = {}
Runtime.__index = Runtime

function M.new(ctx)
    return setmetatable({ ctx = ctx }, Runtime)
end

function Runtime:release_active(job_id)
    local ctx = self.ctx
    local job = ctx.state.store.jobs[job_id]

    ctx.model.release_lock(ctx.state, job, ctx.now(), ctx.service_run_id)

    if ctx.state.active_job and ctx.state.active_job.job_id == job_id then
        ctx.model.clear_active_job(ctx.state)
    end

    if job then
        local ok, err = ctx.store_sync.save_job(ctx.repo, job)
        if not ok then
            ctx.on_store_error(job_id, err)
        end
    end

    -- Important: releasing the active slot may make a resumable reconcile
    -- job admissible immediately. Signal the main loop so it can reconsider
    -- resumable work even if no further observer event arrives.
    ctx.changed:signal()
end

function Runtime:spawn_runner(mode, job)
    local ctx = self.ctx
    local backend = ctx.state.backends[job.component]
    if not backend then return nil, 'backend_missing' end
    local child, err = ctx.service_scope:child()
    if not child then return nil, err end
    local stage_source = nil
    if mode == 'stage' then
        local component_cfg = ctx.state.cfg.components[job.component]
        if type(component_cfg) == 'table' and component_cfg.backend == 'mcu_component' then
            if type(job.artifact_ref) ~= 'string' or job.artifact_ref == '' then
                return nil, 'missing_artifact_ref'
            end
            local opened, oerr = ctx.artifact_open(job.artifact_ref)
            if not opened then return nil, oerr or 'artifact_open_failed' end
            stage_source = opened
        end
    end
    ctx.model.acquire_lock(ctx.state, job, ctx.now(), ctx.service_run_id)
    local ok, save_err = ctx.store_sync.save_job(ctx.repo, job)
    if not ok then ctx.on_store_error(job.job_id, save_err) end
    local cfg_reconcile = ctx.state.cfg.reconcile
    local snapshot = ctx.copy_job(job)
    local spawned, spawn_err = child:spawn(function()
        if mode == 'stage' then
            return ctx.runner.run_stage(ctx.conn, snapshot, backend, ctx.runner_tx, stage_source)
        elseif mode == 'commit' then
            return ctx.runner.run_commit(ctx.conn, snapshot, backend, ctx.runner_tx, cfg_reconcile)
        else
            return ctx.runner.run_reconcile(ctx.conn, snapshot, backend, ctx.runner_tx, cfg_reconcile, ctx.observer)
        end
    end)
    if not spawned then
        ctx.model.release_lock(ctx.state, job, ctx.now(), ctx.service_run_id)
        local ok2, err2 = ctx.store_sync.save_job(ctx.repo, job)
        if not ok2 then ctx.on_store_error(job.job_id, err2) end
        return nil, spawn_err
    end
    ctx.model.set_active_job(ctx.state, { job_id = job.job_id, scope = child, component = job.component, started_at = ctx.now(), mode = mode })
    ctx.changed:signal()
    return true, nil
end

function Runtime:handle_runner_event(ev)
    local ctx = self.ctx
    if not (ev and ev.job_id) then return end
    local job = ctx.state.store.jobs[ev.job_id]
    if not job then return end
    if ev.tag == 'failed' then
        ctx.patch_job(job, { state = 'failed', stage = 'failed', error = tostring(ev.err or 'failed'), next_step = nil })
        ctx.release_artifact_if_present(job)
    elseif ev.tag == 'staged' then
        if ev.pre_commit_incarnation ~= nil then job.pre_commit_incarnation = ev.pre_commit_incarnation end
        if ev.pre_commit_boot_id ~= nil then job.pre_commit_boot_id = ev.pre_commit_boot_id end
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
        ctx.patch_job(job, {
            state = 'awaiting_return',
            stage = 'awaiting_member_return',
            result = ev.result,
            error = nil,
            next_step = 'reconcile',
        }, { runtime_merge = {
            awaiting_return_run_id = ctx.service_run_id,
            awaiting_return_mono = ctx.now(),
        } })
    elseif ev.tag == 'reconciled_success' then
        ctx.patch_job(job, {
            state = 'succeeded',
            stage = 'succeeded',
            result = ev.result,
            error = nil,
            next_step = nil,
            post_commit_incarnation = type(ev.result) == 'table' and ev.result.observed_incarnation or nil,
        })
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
        }, { no_save = true, no_signal = true })
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
    local current_active = ctx.state.active_job and ctx.state.active_job.job_id or nil

    self:release_active(ev.job_id)

    local job = ctx.state.store.jobs[ev.job_id]
    if not (ev and job and current_active == ev.job_id) then
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

    -- If a successful commit worker has already transitioned the job into
    -- awaiting_return/reconcile, hand off directly to the reconcile worker.
    -- This avoids a race where the device/fabric observer state changes before
    -- the main loop notices that the active slot has been released.
    if job.state == 'awaiting_return' and job.next_step == 'reconcile' then
        ctx.store_sync.flush_jobs(ctx.repo, ctx.state, ctx.on_store_error)
        local rok, rerr = self:spawn_runner('reconcile', job)
        if not rok then
            ctx.patch_job(job, {
                state = 'failed',
                stage = 'failed',
                error = tostring(rerr or 'reconcile_spawn_failed'),
                next_step = nil,
            })
        end
        return
    end

    if job.state == 'awaiting_commit' and job.auto_commit then
        local ok3, aerr3 = ctx.model.can_activate(ctx.state, job)
        if ok3 then
            ctx.patch_job(job, {
                state = 'awaiting_return',
                stage = 'commit_sent',
                next_step = 'reconcile',
                error = nil,
            }, {
                runtime_merge = {
                    awaiting_return_run_id = ctx.service_run_id,
                    awaiting_return_mono = ctx.now(),
                }
            })

            ctx.store_sync.flush_jobs(ctx.repo, ctx.state, ctx.on_store_error)

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
                error = tostring(aerr3 or 'auto_commit_blocked'),
                next_step = nil,
            })
        end
    end
end

return M
