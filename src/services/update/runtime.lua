-- services/update/runtime.lua
--
-- Runtime orchestration around the single active worker slot.

local M = {}
local Runtime = {}
Runtime.__index = Runtime

function M.new(ctx)
  return setmetatable({
    ctx = ctx,
  }, Runtime)
end

function Runtime:current()
  return self.ctx.state.active_job
end

function Runtime:is_idle()
  return self.ctx.state.active_job == nil
end

function Runtime:active_join_op()
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

function Runtime:release_active(job_id)
  local ctx = self.ctx
  local job = ctx.state.store.jobs[job_id]

  ctx.model.release_lock(ctx.state, job, ctx.now(), ctx.service_run_id)
  if ctx.state.active_job and ctx.state.active_job.job_id == job_id then
    ctx.model.clear_active_job(ctx.state)
  end

  if job then
    local ok, err = ctx.save_job(job)
    if not ok then ctx.on_store_error(job_id, err) end
  end

  ctx.changed:signal()
end

function Runtime:spawn_runner(mode, job)
  local ctx = self.ctx
  local backend = ctx.state.backends[job.component]
  if not backend then return nil, 'backend_missing' end

  local child, err = ctx.service_scope:child()
  if not child then return nil, err end

  ctx.model.acquire_lock(ctx.state, job, ctx.now(), ctx.service_run_id)
  local ok, save_err = ctx.save_job(job)
  if not ok then ctx.on_store_error(job.job_id, save_err) end

  local cfg_reconcile = ctx.state.cfg.reconcile
  local snapshot = ctx.copy_job(job)
  local spawned, spawn_err = child:spawn(function()
    return ctx.runner.run(mode, ctx.conn, snapshot, backend, ctx.runner_tx, cfg_reconcile, ctx.observer, ctx)
  end)
  if not spawned then
    ctx.model.release_lock(ctx.state, job, ctx.now(), ctx.service_run_id)
    local ok2, err2 = ctx.save_job(job)
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

function Runtime:spawn_reconcile(job)
  local ctx = self.ctx

  ctx.flush_jobs()

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

  ctx.flush_publications()

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
    ctx.publish_job_only(job)

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
  local current_active = self:current()

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
