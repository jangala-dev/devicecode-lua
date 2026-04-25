-- services/update/runner.lua
--
-- Bounded update work units.

local fibers = require 'fibers'
local scope = require 'fibers.scope'
local await_mod = require 'services.update.await'

local M = {}

local function emit(tx, ev)
  tx:send(ev)
end

local function runner_context(conn, job, backend, tx, reconcile_cfg, observe, service_ctx)
  return {
    conn = conn,
    job = job,
    backend = backend,
    tx = tx,
    reconcile_cfg = reconcile_cfg,
    observe = observe,
    service_ctx = service_ctx,
    emit = function(ev)
      emit(tx, ev)
    end,
  }
end

local function current_component_state(ctx)
  local obs = ctx.observe or (ctx.service_ctx and ctx.service_ctx.observer) or nil
  if not (obs and obs.component_state_for) then return nil end
  return obs:component_state_for(ctx.job.component)
end

local function stage_body(ctx)
  local service_ctx = ctx.service_ctx
  local job, backend = ctx.job, ctx.backend

  local status_before = current_component_state(ctx)
  local sw = type(status_before) == 'table' and status_before.software or nil
  local pre_commit_boot_id = nil
  if type(sw) == 'table' then
    pre_commit_boot_id = sw.boot_id
  end

  local prep, perr = backend:prepare(ctx.conn, job)
  if prep == nil then
    ctx.emit({
      tag = 'failed',
      job_id = job.job_id,
      err = tostring(perr or 'prepare_failed'),
    })
    return
  end

  local staged, serr = backend:stage(ctx.conn, job, service_ctx)
  if staged == nil then
    ctx.emit({
      tag = 'failed',
      job_id = job.job_id,
      err = tostring(serr or 'stage_failed'),
    })
    return
  end

  ctx.emit({
    tag = 'staged',
    job_id = job.job_id,
    staged = staged,
    pre_commit_boot_id = pre_commit_boot_id,
  })
end

local function commit_body(ctx)
  local committed, cerr = ctx.backend:commit(ctx.conn, ctx.job, ctx.service_ctx)
  if committed == nil then
    ctx.emit({
      tag = 'failed',
      job_id = ctx.job.job_id,
      err = tostring(cerr or 'commit_failed'),
    })
    return
  end

  ctx.emit({
    tag = 'commit_started',
    job_id = ctx.job.job_id,
    result = committed,
  })
end

local function current_version(observe)
  return (observe and observe.version and observe:version()) or 0
end

local function reconcile_body(ctx)
  local outcome, result = await_mod.until_changed_or_timeout({
    timeout_s = ctx.reconcile_cfg.timeout_s,
    version = function()
      return current_version(ctx.observe)
    end,
    changed_op = function(seen)
      return ctx.observe:changed_op(seen)
    end,
    evaluate = function()
      local component_state = current_component_state(ctx)
      return ctx.backend.evaluate and ctx.backend:evaluate(ctx.job, component_state) or nil
    end,
    on_progress = function(progress)
      ctx.emit({
        tag = 'reconcile_progress',
        job_id = ctx.job.job_id,
        result = progress,
      })
    end,
  })

  if outcome == 'success' then
    ctx.emit({
      tag = 'reconciled_success',
      job_id = ctx.job.job_id,
      result = result,
    })
  elseif outcome == 'failure' then
    ctx.emit({
      tag = 'reconciled_failure',
      job_id = ctx.job.job_id,
      result = result,
      err = tostring(result and result.error or 'failed'),
    })
  elseif outcome == 'timeout' then
    ctx.emit({
      tag = 'timed_out',
      job_id = ctx.job.job_id,
      err = 'timeout',
    })
  else
    error('unexpected_await_outcome:' .. tostring(outcome), 0)
  end
end

local BODY = {
  stage = stage_body,
  commit = commit_body,
  reconcile = reconcile_body,
}

local function run_work_unit(ctx, body)
  local st, _report, primary = fibers.run_scope(function()
    return body(ctx)
  end)

  if st == 'ok' then
    return true
  elseif st == 'cancelled' then
    error(scope.cancelled(primary), 0)
  else
    ctx.emit({
      tag = 'failed',
      job_id = ctx.job.job_id,
      err = tostring(primary or 'runner_failed'),
    })
    return nil, primary
  end
end

function M.run(mode, conn, job, backend, tx, reconcile_cfg, observe, service_ctx)
  local body = BODY[mode]
  if not body then
    error('unknown_runner_mode: ' .. tostring(mode), 2)
  end
  local ctx = runner_context(conn, job, backend, tx, reconcile_cfg, observe, service_ctx)
  return run_work_unit(ctx, body)
end

return M
