-- services/update/bundled_reconcile.lua
--
-- Reconciles components against bundled-image intent declared in cfg/update.
-- Durable intent lives only in cfg/update. This module publishes observed
-- reconcile truth under state/update/component/<component> and creates normal
-- update workflow jobs when policy says to converge automatically.

local uuid = require 'uuid'

local M = {}
local Bundled = {}
Bundled.__index = Bundled

local function copy(v, seen)
  if type(v) ~= 'table' then return v end
  seen = seen or {}
  if seen[v] then return seen[v] end
  local out = {}
  seen[v] = out
  for k, vv in pairs(v) do out[copy(k, seen)] = copy(vv, seen) end
  return out
end

local function stable_encode(v)
  local tv = type(v)
  if tv == 'nil' then return 'nil' end
  if tv == 'boolean' or tv == 'number' then return tostring(v) end
  if tv == 'string' then return string.format('%q', v) end
  if tv ~= 'table' then return '<' .. tv .. '>' end
  local is_array = true
  local n = #v
  for k in pairs(v) do
    if type(k) ~= 'number' or k < 1 or k > n or k % 1 ~= 0 then
      is_array = false
      break
    end
  end
  if is_array then
    local parts = {}
    for i = 1, n do parts[#parts + 1] = stable_encode(v[i]) end
    return '[' .. table.concat(parts, ',') .. ']'
  end
  local keys, parts = {}, {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, k in ipairs(keys) do parts[#parts + 1] = stable_encode(k) .. ':' .. stable_encode(v[k]) end
  return '{' .. table.concat(parts, ',') .. '}'
end

local function software_identity(component_state)
  local sw = type(component_state) == 'table' and component_state.software or nil
  if type(sw) ~= 'table' or sw.image_id == nil then return nil end
  return {
    version = sw.version,
    build_id = sw.build,
    image_id = sw.image_id,
    boot_id = sw.boot_id,
  }
end

local function image_identity(inspected)
  local build = type(inspected) == 'table' and inspected.build or nil
  local payload = type(inspected) == 'table' and inspected.payload or nil
  if type(build) ~= 'table' then return nil end
  return {
    version = build.version,
    build_id = build.build_id,
    image_id = build.image_id,
    payload_sha256 = type(payload) == 'table' and payload.sha256 or nil,
  }
end

local function identities_match(current, desired)
  return type(current) == 'table'
    and type(desired) == 'table'
    and desired.image_id ~= nil
    and current.image_id == desired.image_id
end

local function cm5_release_id(ctx, cfg)
  local cm5 = ctx.observer:component_state_for('cm5')
  local sw = type(cm5) == 'table' and cm5.software or nil
  if type(sw) ~= 'table' then return nil end
  local field = cfg.cm5_release_id_field or 'image_id'
  return sw[field] or sw.image_id or sw.boot_id or sw.version
end

local function is_terminal(ctx, job)
  return job and ctx.model.is_terminal(job.state)
end

local function matching_job(ctx, component, desired)
  for _, id in ipairs(ctx.state.store.order) do
    local job = ctx.state.store.jobs[id]
    local meta = job and job.metadata or nil
    local b = type(meta) == 'table' and meta.bundled or nil
    if job and job.component == component and type(b) == 'table' then
      if desired.image_id and b.image_id == desired.image_id then return job end
    end
  end
  return nil
end

local function bundled_cache_key(component, bcfg, desired_release_id)
  return table.concat({
    tostring(component),
    tostring(desired_release_id or ''),
    stable_encode(type(bcfg) == 'table' and (bcfg.source or {}) or {}),
    stable_encode(type(bcfg) == 'table' and (bcfg.target or {}) or {}),
    stable_encode(type(bcfg) == 'table' and (bcfg.preflight or {}) or {}),
  }, '|')
end

local function bundled_cfg_for(ctx, component)
  local cfg = type(ctx.state) == 'table' and ctx.state.cfg or nil
  local bundled = type(cfg) == 'table' and cfg.bundled or nil
  local comps = type(bundled) == 'table' and bundled.components or nil
  local rec = type(comps) == 'table' and comps[component] or nil
  if type(rec) == 'table' and rec.enabled == true then return rec end
  return nil
end

local function follow_mode_default(bcfg)
  return (type(bcfg) == 'table' and bcfg.follow_mode_default == 'hold') and 'hold' or 'auto'
end

local function latest_manual_success_job(ctx, component, current)
  if type(current) ~= 'table' or current.image_id == nil then return nil end
  local order = type(ctx.state.store) == 'table' and ctx.state.store.order or {}
  local jobs = type(ctx.state.store) == 'table' and ctx.state.store.jobs or {}
  for i = #order, 1, -1 do
    local id = order[i]
    local job = jobs[id]
    local meta = job and job.metadata or nil
    if job and job.component == component and job.state == 'succeeded' and not (type(meta) == 'table' and type(meta.bundled) == 'table') then
      local expected = job.expected_image_id
      if expected ~= nil and expected == current.image_id then
        return job
      end
      local result = type(job.result) == 'table' and job.result or nil
      if type(result) == 'table' and result.current_image_id == current.image_id then
        return job
      end
    end
  end
  return nil
end

function M.new(ctx, commands)
  return setmetatable({ ctx = ctx, commands = commands, probe_cache = {} }, Bundled)
end

function Bundled:publish_component(component, rec)
  rec = rec or {}
  rec.kind = 'update.component-summary'
  rec.component = component
  rec.updated_at = rec.updated_at or self.ctx.now()
  self.ctx.state.component_summaries = self.ctx.state.component_summaries or {}
  local copier = self.ctx.model and self.ctx.model.copy_value or copy
  self.ctx.state.component_summaries[component] = copier(rec)
  self.ctx.conn:retain(self.ctx.topics.component_summary(component), rec)
  if self.ctx.model and self.ctx.model.mark_summary_dirty then
    self.ctx.model.mark_summary_dirty(self.ctx.state)
  end
  return true, nil
end

function Bundled:probe_desired(component, bcfg, desired_release_id)
  local cache_key = bundled_cache_key(component, bcfg, desired_release_id)
  local cached = self.probe_cache[component]
  if cached and cached.key == cache_key then return copy(cached.desired), nil end

  local ref, desc, aerr = self.ctx.artifacts:resolve_job_artifact({
    component = component,
    artifact = { kind = 'bundled' },
    metadata = { source = 'bundled_probe' },
  })
  if not ref then return nil, aerr end
  self.ctx.artifacts:delete(ref)

  local inspected = type(desc) == 'table' and desc.mcu_image or nil
  local desired = image_identity(inspected)
  if not desired then return nil, nil end
  desired.source = 'bundled'
  desired.cm5_release_id = desired_release_id
  self.probe_cache[component] = { key = cache_key, desired = copy(desired) }
  return desired, nil
end

function Bundled:effective_follow(component, bcfg, current, desired)
  local follow = follow_mode_default(bcfg)
  local manual_job_id = nil
  if follow ~= 'hold' and type(current) == 'table' and type(desired) == 'table' and not identities_match(current, desired) then
    local job = latest_manual_success_job(self.ctx, component, current)
    if job then
      follow = 'hold'
      manual_job_id = job.job_id
    end
  end
  return follow, manual_job_id
end

function Bundled:mark_job_success(job, result)
  if not (job and job.component) then return end

  local current_state = self.ctx.observer:component_state_for(job.component)
  local current = software_identity(current_state)
  local meta = type(job.metadata) == 'table' and job.metadata or {}
  local bcfg = bundled_cfg_for(self.ctx, job.component)
  local desired = nil
  if bcfg then
    local desired_release_id = cm5_release_id(self.ctx, bcfg)
    desired = self:probe_desired(job.component, bcfg, desired_release_id)
  end

  if type(desired) == 'table' then
    local follow, manual_job_id = self:effective_follow(job.component, bcfg, current, desired)
    local is_manual_success = (meta.bundled == nil) and (follow == 'hold')
    local manual_marker_job_id = is_manual_success and job.job_id or manual_job_id

    if identities_match(current, desired) then
      self:publish_component(job.component, {
        source = 'bundled',
        follow_mode = follow,
        sync_state = 'satisfied',
        last_result = is_manual_success and 'manual_success_hold' or 'satisfied',
        last_job_id = job.job_id,
        last_manual_job_id = manual_marker_job_id,
        current_image_id = current and current.image_id or nil,
        bundled_image_id = desired.image_id,
        desired = copy(desired),
        result = copy(result),
      })
      return
    end

    if follow == 'hold' then
      self:publish_component(job.component, {
        source = 'bundled',
        follow_mode = 'hold',
        sync_state = 'diverged',
        last_result = is_manual_success and 'manual_success_hold' or 'held',
        last_job_id = job.job_id,
        last_manual_job_id = manual_marker_job_id,
        current_image_id = current and current.image_id or nil,
        bundled_image_id = desired.image_id,
        desired = copy(desired),
        result = copy(result),
      })
      return
    end

    self:publish_component(job.component, {
      source = 'bundled',
      follow_mode = 'auto',
      sync_state = 'pending',
      last_result = 'pending',
      last_job_id = job.job_id,
      current_image_id = current and current.image_id or nil,
      bundled_image_id = desired.image_id,
      desired = copy(desired),
      result = copy(result),
    })
    return
  end

  self:publish_component(job.component, {
    source = meta.source or 'manual',
    sync_state = 'satisfied',
    last_result = job.state,
    last_job_id = job.job_id,
    current_image_id = current and current.image_id or nil,
    result = copy(result),
  })
end

function Bundled:maybe_run()
  local cfg = self.ctx.state.cfg.bundled or {}
  local components = type(cfg.components) == 'table' and cfg.components or {}
  for component, bcfg in pairs(components) do
    if type(bcfg) == 'table' and bcfg.enabled == true then
      self:maybe_component(component, bcfg)
    end
  end
end

function Bundled:maybe_component(component, bcfg)
  if self.ctx.state.active_job or self.ctx.state.locks.global then return end

  local current_state = self.ctx.observer:component_state_for(component)
  if type(current_state) ~= 'table' or current_state.available == false then return end
  if current_state.ready ~= true then return end
  local current = software_identity(current_state)
  if not current then return end

  local desired_release_id = cm5_release_id(self.ctx, bcfg)
  local desired, aerr = self:probe_desired(component, bcfg, desired_release_id)
  if not desired then
    if aerr then
      self.ctx.svc:obs_log('warn', { what = 'bundled_artifact_unavailable', component = component, err = tostring(aerr) })
      self:publish_component(component, {
        source = 'bundled',
        follow_mode = follow_mode_default(bcfg),
        sync_state = 'unavailable',
        last_result = tostring(aerr),
      })
    end
    return
  end

  local follow, manual_job_id = self:effective_follow(component, bcfg, current, desired)
  if identities_match(current, desired) then
    self:publish_component(component, {
      source = 'bundled',
      follow_mode = follow_mode_default(bcfg),
      sync_state = 'satisfied',
      last_result = 'satisfied',
      current_image_id = current.image_id,
      bundled_image_id = desired.image_id,
      desired = copy(desired),
    })
    return
  end

  if follow == 'hold' then
    self:publish_component(component, {
      source = 'bundled',
      follow_mode = 'hold',
      sync_state = 'diverged',
      last_result = 'held',
      last_manual_job_id = manual_job_id,
      current_image_id = current.image_id,
      bundled_image_id = desired.image_id,
      desired = copy(desired),
    })
    return
  end

  self:publish_component(component, {
    source = 'bundled',
    follow_mode = 'auto',
    sync_state = 'pending',
    last_result = 'pending',
    current_image_id = current.image_id,
    bundled_image_id = desired.image_id,
    desired = copy(desired),
  })

  local job = matching_job(self.ctx, component, desired)
  if job and not is_terminal(self.ctx, job) then
    if job.state == 'created' then
      self.commands:start_job(job)
    elseif job.state == 'awaiting_commit' and job.auto_commit then
      self.commands:commit_job(job)
    end
    return
  end

  local new_job, err = self.commands:create_job_from_spec({
    job_id = tostring(uuid.new()),
    component = component,
    artifact_ref = nil,
    artifact_meta = nil,
    expected_image_id = desired.image_id,
    metadata = {
      source = 'bundled',
      bundled = copy(desired),
    },
    auto_start = bcfg.auto_start ~= false,
    auto_commit = bcfg.auto_commit ~= false,
  })
  if not new_job then
    self.ctx.svc:obs_log('warn', { what = 'bundled_job_create_failed', component = component, err = tostring(err) })
    return
  end

  local aref, ameta, rerr = self.ctx.artifacts:resolve_job_artifact({
    component = component,
    artifact = { kind = 'bundled' },
    metadata = new_job.metadata,
  })
  if not aref then
    self.ctx.patch_job(new_job, { state = 'failed', stage = 'failed', error = tostring(rerr or 'bundled_artifact_failed') })
    return
  end
  new_job.artifact_ref = aref
  new_job.artifact_meta = ameta
  self.ctx.patch_job(new_job, { expected_image_id = desired.image_id })
  self:publish_component(component, {
    source = 'bundled',
    follow_mode = 'auto',
    sync_state = 'attempting',
    last_result = 'job-created',
    current_image_id = current.image_id,
    bundled_image_id = desired.image_id,
    desired = copy(desired),
    last_attempt_job_id = new_job.job_id,
  })

  if new_job.auto_start then self.commands:start_job(new_job) end
end

return M
