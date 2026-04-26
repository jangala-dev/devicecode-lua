-- services/update/commands.lua
--
-- Update command handlers.

local uuid = require 'uuid'

local M = {}
local Commands = {}
Commands.__index = Commands

local DO_ACTIONS = {
  start = { method = 'start_job', wrap_job = true },
  commit = { method = 'commit_job', wrap_job = true },
  cancel = { method = 'cancel_job', wrap_job = true },
  retry = { method = 'retry_job', wrap_job = true },
  discard = { method = 'discard_job', wrap_job = false },
}

function M.new(ctx)
  return setmetatable({ ctx = ctx }, Commands)
end

function Commands:create_job_from_spec(spec)
  local ctx = self.ctx
  local job = ctx.model.create_job(ctx.state, spec, ctx.now(), ctx.service_run_id)
  local ok, err = ctx.save_job(job)
  if not ok then return nil, err end
  ctx.changed:signal()
  return job, nil
end

function Commands:create_job(payload)
  local ctx = self.ctx
  local component = payload and payload.component or nil
  if type(component) ~= 'string' or component == '' then
    return nil, 'component_required'
  end
  if not ctx.state.cfg.components[component] then
    return nil, 'unknown_component'
  end

  local artifact_ref, artifact_meta, aerr = ctx.artifacts:resolve_job_artifact(payload)
  if aerr ~= nil then
    return nil, aerr
  end

  local metadata = type(payload.metadata) == 'table' and ctx.model.copy_value(payload.metadata) or {}
  local expected_image_id = payload.expected_image_id
  local img = type(artifact_meta) == 'table' and artifact_meta.mcu_image or nil
  if expected_image_id == nil and type(img) == 'table' and type(img.build) == 'table' then
    expected_image_id = img.build.image_id
  end
  if type(payload.artifact) == 'table' and payload.artifact.kind == 'bundled' then
    metadata.source = metadata.source or 'bundled'
    if type(img) == 'table' and type(img.build) == 'table' then
      metadata.bundled = {
        version = img.build.version,
        build_id = img.build.build_id,
        image_id = img.build.image_id,
        payload_sha256 = type(img.payload) == 'table' and img.payload.sha256 or nil,
      }
    end
  end
  if next(metadata) == nil then metadata = nil end

  return self:create_job_from_spec({
    job_id = tostring(uuid.new()),
    offer_id = payload.offer_id,
    component = component,
    artifact_ref = artifact_ref,
    artifact_meta = artifact_meta,
    expected_image_id = expected_image_id,
    metadata = metadata,
    auto_start = (type(payload.options) == 'table' and payload.options.auto_start == true),
    auto_commit = (type(payload.options) == 'table' and payload.options.auto_commit == true),
  })
end

function Commands:clone_job_for_retry(src)
  local job, err = self:create_job_from_spec({
    job_id = tostring(uuid.new()),
    component = src.component,
    offer_id = src.offer_id,
    artifact_ref = src.artifact_ref,
    artifact_meta = src.artifact_meta,
    expected_image_id = src.expected_image_id,
    metadata = self.ctx.model.copy_value(src.metadata),
  })
  if not job then return nil, err end

  self.ctx.patch_job(src, {
    state = 'superseded',
    next_step = nil,
    error = nil,
  })

  return job, nil
end

function Commands:start_job(job)
  local ctx = self.ctx
  if job.state ~= 'created' then return nil, 'job_not_startable' end

  local ok, err = ctx.model.can_activate(ctx.state, job)
  if not ok then return nil, err end

  ctx.patch_job(job, {
    state = 'staging',
    stage = 'validating_artifact',
    next_step = 'stage',
    error = nil,
  })

  local wok, werr = ctx.runtime:spawn_runner('stage', job)
  if not wok then
    ctx.patch_job(job, {
      state = 'failed',
      stage = 'failed',
      error = tostring(werr),
      next_step = nil,
    })
    return nil, tostring(werr)
  end

  return ctx.projection.public_job(job), nil
end

function Commands:commit_job(job)
  local ctx = self.ctx
  if job.state ~= 'awaiting_commit' then return nil, 'job_not_committable' end

  local ok, err = ctx.model.can_activate(ctx.state, job)
  if not ok then return nil, err end

  ctx.enter_awaiting_return(job, 'commit_sent')
  ctx.flush_jobs()

  local wok, werr = ctx.runtime:spawn_runner('commit', job)
  if not wok then
    ctx.patch_job(job, {
      state = 'failed',
      stage = 'failed',
      error = tostring(werr),
      next_step = nil,
    })
    return nil, tostring(werr)
  end

  return ctx.projection.public_job(job), nil
end

function Commands:cancel_job(job)
  local ctx = self.ctx
  if ctx.model.ACTIVE_STATES[job.state] then return nil, 'job_active' end
  if ctx.model.TERMINAL_STATES[job.state] then return nil, 'job_terminal' end
  if job.state ~= 'created' and job.state ~= 'awaiting_commit' then
    return nil, 'job_not_cancellable'
  end

  ctx.patch_job(job, {
    state = 'cancelled',
    next_step = nil,
    error = nil,
  })
  return ctx.projection.public_job(job), nil
end

function Commands:retry_job(job)
  if not self.ctx.model.job_actions(job).retry then
    return nil, 'job_not_retryable'
  end
  local new_job, err = self:clone_job_for_retry(job)
  if not new_job then return nil, err end
  return self.ctx.projection.public_job(new_job), nil
end

function Commands:discard_job(job)
  local ctx = self.ctx
  if not ctx.model.is_terminal(job.state) then
    return nil, 'job_not_discardable'
  end

  if type(job.artifact_ref) == 'string' and job.artifact_ref ~= '' then
    ctx.release_artifact_if_present(job)
  end

  local _ = ctx.delete_job(job.job_id)
  ctx.model.remove_job(ctx.state, job.job_id)
  ctx.conn:unretain(ctx.projection.job_topic(job.job_id))
  ctx.changed:signal()

  return { ok = true }, nil
end

function Commands:handle_create(req)
  local payload = req.payload or {}
  local job, err = self:create_job(payload)
  if not job then
    req:fail(err)
    return
  end

  if job.auto_start then
    local view, serr = self:start_job(job)
    if not view then
      req:fail(serr)
      return
    end
    req:reply({ ok = true, job = view })
    return
  end

  req:reply({ ok = true, job = self.ctx.projection.public_job(job) })
end

function Commands:handle_method(req, op)
  local payload = req.payload or {}
  local action = DO_ACTIONS[op]
  if not action then
    req:fail('invalid_op')
    return
  end

  local job = self.ctx.state.store.jobs[payload.job_id]
  if not job then
    req:fail('unknown_job')
    return
  end

  local value, err = self[action.method](self, job)
  if value == nil then
    req:fail(err)
    return
  end

  if action.wrap_job then
    req:reply({ ok = true, job = value })
  else
    req:reply(value)
  end
end

function Commands:handle_do(req)
  local payload = req.payload or {}
  local op = payload.op
  local action = DO_ACTIONS[op]
  if not action then
    req:fail('invalid_op')
    return
  end

  local job = self.ctx.state.store.jobs[payload.job_id]
  if not job then
    req:fail('unknown_job')
    return
  end

  local value, err = self[action.method](self, job)
  if value == nil then
    req:fail(err)
    return
  end

  if action.wrap_job then
    req:reply({ ok = true, job = value })
  else
    req:reply(value)
  end
end

function Commands:handle_get(req)
  local job = self.ctx.state.store.jobs[(req.payload or {}).job_id]
  if not job then
    req:fail('unknown_job')
  else
    req:reply({ ok = true, job = self.ctx.projection.public_job(job) })
  end
end

function Commands:handle_list(req)
  req:reply({ ok = true, jobs = self.ctx.projection.public_jobs(self.ctx.state) })
end

return M
