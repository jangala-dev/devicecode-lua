-- services/update.lua
--
-- Update service shell.

local fibers        = require 'fibers'
local pulse         = require 'fibers.pulse'
local mailbox       = require 'fibers.mailbox'
local base          = require 'devicecode.service_base'
local cap_sdk       = require 'services.hal.sdk.cap'
local job_store     = require 'services.update.job_store'
local model         = require 'services.update.model'
local projection    = require 'services.update.projection'
local topics        = require 'services.update.topics'
local observe_mod   = require 'services.update.observe'
local crypto_mod    = require 'services.update.crypto'
local runner        = require 'services.update.runner'
local runtime_mod   = require 'services.update.runtime'
local artifacts_mod = require 'services.update.artifacts'
local commands_mod  = require 'services.update.commands'
local bundled_reconcile_mod = require 'services.update.bundled_reconcile'
local component_backend_mod = require 'services.update.backends.component_proxy'
local cm5_backend_mod = require 'services.update.backends.cm5_swupdate'
local mcu_backend_mod = require 'services.update.backends.mcu_component'
local uuid          = require 'uuid'

local named_choice = fibers.named_choice

local M = {}
local SCHEMA = 'devicecode.config/update/1'

local function validate_backend(name, backend)
  if type(backend) ~= 'table' then
    return nil, 'backend_not_table:' .. tostring(name)
  end
  for _, method in ipairs({ 'prepare', 'stage', 'commit', 'evaluate' }) do
    if type(backend[method]) ~= 'function' then
      return nil, 'backend_missing_' .. method .. ':' .. tostring(name)
    end
  end
  return backend, nil
end

local function backend_observe_specs(name, backend, cfg)
  if backend.observe_specs == nil then return {}, nil end
  if type(backend.observe_specs) ~= 'function' then
    return nil, 'backend_bad_observe_specs:' .. tostring(name)
  end
  local specs = backend:observe_specs(cfg)
  if specs == nil then return {}, nil end
  if type(specs) ~= 'table' then
    return nil, 'backend_observe_specs_not_table:' .. tostring(name)
  end
  return specs, nil
end

local function build_backend(component, component_cfg)
  local opts = {
    component = component,
    proxy_mod = component_backend_mod,
  }

  if type(component_cfg) == 'table' then
    for k, v in pairs(component_cfg) do
      if k ~= 'backend' and opts[k] == nil then
        opts[k] = v
      end
    end
  end

  local backend_name = type(component_cfg) == 'table' and component_cfg.backend or nil
  local backend
  if backend_name == 'cm5_swupdate' then
    backend = cm5_backend_mod.new(opts)
  elseif backend_name == 'mcu_component' then
    backend = mcu_backend_mod.new(opts)
  else
    return nil, 'unknown_backend:' .. tostring(backend_name)
  end

  return validate_backend(backend_name .. ':' .. tostring(component), backend)
end


local function discover_raw_host_cap(conn, source, class, id, timeout)
  local listener = cap_sdk.new_raw_host_cap_listener(conn, source, class, id)
  local cap, err = listener:wait_for_cap({ timeout = timeout or 30.0 })
  listener:close()
  return cap, err
end

local function copy_job(job)
  return model.copy_value(job)
end

local function flush_jobs(repo, state, on_error)
  local saved = false
  for _, id in ipairs(state.store.order) do
    if state.dirty_jobs[id] then
      local job = state.store.jobs[id]
      if job then
        local ok, err = repo:save_job(job)
        if not ok and on_error then
          on_error(id, err)
        end
      end
      state.dirty_jobs[id] = nil
      saved = true
    end
  end
  return saved
end

local function emit_job_changed(ctx, public_job)
  if not (ctx and public_job and public_job.job_id) then return end
  ctx.conn:publish(ctx.topics.manager_event('job-changed'), {
    job_id = public_job.job_id,
    component = public_job.component,
    state = public_job.lifecycle and public_job.lifecycle.state or nil,
    stage = public_job.lifecycle and public_job.lifecycle.stage or nil,
    next_step = public_job.lifecycle and public_job.lifecycle.next_step or nil,
    updated_seq = public_job.lifecycle and public_job.lifecycle.updated_seq or nil,
  })
end

local function publish_job_only(ctx, job)
  if not job then return end
  local public_job = ctx.projection.public_job(job)
  ctx.conn:retain(
    ctx.projection.job_topic(job.job_id),
    { job = public_job }
  )
  emit_job_changed(ctx, public_job)
end

local function flush_publications(ctx)
  ctx.flush_jobs()

  for _, id in ipairs(ctx.state.store.order) do
    local job = ctx.state.store.jobs[id]
    if job then
      ctx.conn:retain(
        ctx.projection.job_topic(id),
        { job = ctx.projection.public_job(job) }
      )
    end
  end

  local summary = nil
  if ctx.state.summary_dirty then
    summary = ctx.projection.summary_payload(ctx.state)
    ctx.conn:retain(
      ctx.projection.summary_topic(),
      summary
    )
    ctx.model.set_summary_clean(ctx.state)
  end

  if ctx.state.cfg_bootstrapped and (summary ~= nil or not ctx.state.ready_published) then
    summary = summary or ctx.projection.summary_payload(ctx.state)
    ctx.svc:set_ready(true, {
      jobs_total = summary.counts and summary.counts.total or 0,
      jobs_active = summary.counts and summary.counts.active or 0,
    })
    ctx.state.ready_published = true
  end
end

local function next_update_event_op(state, cfg_watch, endpoints, runner_rx, changed, seen, active_join_op)
  local ops = {
    cfg = cfg_watch:recv_op(),
    create = endpoints.create and endpoints.create:recv_op() or nil,
    start = endpoints.start and endpoints.start:recv_op() or nil,
    commit = endpoints.commit and endpoints.commit:recv_op() or nil,
    cancel = endpoints.cancel and endpoints.cancel:recv_op() or nil,
    retry = endpoints.retry and endpoints.retry:recv_op() or nil,
    discard = endpoints.discard and endpoints.discard:recv_op() or nil,
    get = endpoints.get and endpoints.get:recv_op() or nil,
    list = endpoints.list and endpoints.list:recv_op() or nil,
    ingest_create = endpoints.ingest_create and endpoints.ingest_create:recv_op() or nil,
    ingest_append = endpoints.ingest_append and endpoints.ingest_append:recv_op() or nil,
    ingest_commit = endpoints.ingest_commit and endpoints.ingest_commit:recv_op() or nil,
    ingest_abort = endpoints.ingest_abort and endpoints.ingest_abort:recv_op() or nil,
    runner = runner_rx:recv_op(),
    changed = changed:changed_op(seen):wrap(function(ver)
      return ver
    end),
  }

  for key, rec in pairs(state.component_obs) do
    ops[key] = rec.watch:recv_op()
  end

  if active_join_op then
    ops.active_join = active_join_op
  end

  return named_choice(ops)
end

function M.start(conn, opts)
  opts = opts or {}

  local service_scope = assert(fibers.current_scope())
  local svc = base.new(conn, { name = opts.name or 'update', env = opts.env })
  local heartbeat_s = (type(opts.heartbeat_s) == 'number') and opts.heartbeat_s or 30.0

  svc:announce({
    role = 'update',
    caps = {
      create = true,
      job_do = true,
      get = true,
      list = true,
      summary = true,
    },
  })

  svc:spawn_heartbeat(heartbeat_s, 'tick')
  svc:starting({ jobs_total = 0, jobs_active = 0 })

  local store_cap, serr = discover_raw_host_cap(conn, 'control-store', 'control-store', 'update', 30.0)
  if not store_cap then
    svc:failed(tostring(serr or 'raw host control-store capability not found'))
    error('update: failed to discover raw host control-store/update capability: ' .. tostring(serr), 0)
  end

  local artifact_cap, aerr = discover_raw_host_cap(conn, 'artifact-store', 'artifact-store', 'main', 30.0)
  if not artifact_cap then
    svc:failed(tostring(aerr or 'raw host artifact-store capability not found'))
    error('update: failed to discover raw host artifact-store/main capability: ' .. tostring(aerr), 0)
  end

  local cfg_watch = conn:watch_retained(topics.cfg(), {
    replay = true,
    queue_len = 8,
    full = 'drop_oldest',
  })

  local cfg = model.default_cfg(SCHEMA)
  local repo = job_store.open(store_cap, { namespace = cfg.jobs_namespace })

  local loaded, lerr = repo:load_all()
  if not loaded then
    svc:failed(tostring(lerr))
    error('update: failed to load job store: ' .. tostring(lerr), 0)
  end

  local state = model.new_state(cfg)
  state.cfg_bootstrapped = false
  state.ready_published = false
  model.load_store(state, loaded)

  local changed = pulse.scoped({ close_reason = 'update service stopping' })
  local observer_changed = pulse.scoped({ close_reason = 'update observer stopping' })
  local observer = observe_mod.new({
    on_change = function() observer_changed:signal() end,
  })
  local service_run_id = tostring(uuid.new())
  local runner_tx, runner_rx = mailbox.new(64, { full = 'drop_oldest' })

  local function now()
    return svc:now()
  end

  local function on_store_error(job_id, err)
    svc:obs_log('error', {
      what = 'job_save_failed',
      err = tostring(err),
      job_id = job_id,
    })
  end

  local ctx = {
    conn = conn,
    state = state,
    model = model,
    projection = projection,
    repo = repo,
    store_cap = store_cap,
    artifact_cap = artifact_cap,
    cap_sdk = cap_sdk,
    topics = topics,
    crypto = crypto_mod.new({ conn = conn }),
    ingests = {},
    service_scope = service_scope,
    service_run_id = service_run_id,
    now = now,
    changed = changed,
    observer = observer,
    observer_changed_op = function(last_seen)
      return observer_changed:changed_op(last_seen)
    end,
    runner = runner,
    runner_tx = runner_tx,
    on_store_error = on_store_error,
    copy_job = copy_job,
    svc = svc,
  }

  function ctx.save_job(job)
    return repo:save_job(job)
  end

  function ctx.delete_job(job_id)
    return repo:delete_job(job_id)
  end

  function ctx.flush_jobs()
    return flush_jobs(repo, state, on_store_error)
  end

  function ctx.publish_job_only(job)
    return publish_job_only(ctx, job)
  end

  function ctx.flush_publications()
    return flush_publications(ctx)
  end

  local function patch_job(job, patch, opts_)
    opts_ = opts_ or {}

    model.patch_job(state, job, patch, now(), service_run_id, opts_)

    if not opts_.no_save then
      local ok, err = ctx.save_job(job)
      if not ok then on_store_error(job and job.job_id, err) end
    end

    if not opts_.no_signal then
      changed:signal()
    end
  end
  ctx.patch_job = patch_job

  local function enter_awaiting_return(job, stage, result, opts_)
    opts_ = opts_ or {}

    local runtime_merge = model.copy_value(opts_.runtime_merge) or {}
    runtime_merge.awaiting_return_run_id = service_run_id
    runtime_merge.awaiting_return_mono = now()

    patch_job(job, {
      state = 'awaiting_return',
      stage = stage or 'awaiting_member_return',
      next_step = 'reconcile',
      error = nil,
      result = result,
    }, {
      no_save = opts_.no_save,
      no_signal = opts_.no_signal,
      runtime_merge = runtime_merge,
    })
  end
  ctx.enter_awaiting_return = enter_awaiting_return

  local artifacts = artifacts_mod.new(ctx)
  ctx.artifacts = artifacts
  ctx.artifact_open = function(...)
    return artifacts:open(...)
  end

  local commands = commands_mod.new(ctx)
  ctx.commands = commands

  local function release_artifact_if_present(job)
    if not job or type(job.artifact_ref) ~= 'string' or job.artifact_ref == '' then
      return
    end

    local ref = job.artifact_ref
    local ok, err = artifacts:delete(ref)
    if not ok and err ~= 'not_found' then
      svc:obs_log('warn', {
        what = 'artifact_delete_failed',
        artifact_ref = ref,
        err = tostring(err),
      })
      return
    end

    job.artifact_ref = nil
    job.artifact_released_at = now()
    model.touch_job(state, job, now(), service_run_id, false, nil)

    local sok, serr2 = ctx.save_job(job)
    if not sok then on_store_error(job.job_id, serr2) end

    model.mark_job_dirty(state, job.job_id)
    changed:signal()
  end
  ctx.release_artifact_if_present = release_artifact_if_present

  local runtime = runtime_mod.new(ctx)
  ctx.runtime = runtime

  local bundled = bundled_reconcile_mod.new(ctx, commands)
  ctx.bundled = bundled
  ctx.on_job_succeeded = function(job, result)
    bundled:mark_job_success(job, result)
  end

  local function rebuild_backends()
    state.backends = {}
    for component, ccfg in pairs(state.cfg.components) do
      local backend, berr = build_backend(component, ccfg)
      if backend then
        state.backends[component] = backend
      else
        svc:obs_log('warn', {
          what = 'backend_build_failed',
          component = component,
          err = tostring(berr),
        })
      end
    end
  end

  local function rebuild_component_obs()
    for _, rec in pairs(state.component_obs) do
      rec.watch:unwatch()
    end
    state.component_obs = {}

    for component, ccfg in pairs(state.cfg.components) do
      local backend = state.backends[component]
      if backend then
        local specs, serr = backend_observe_specs(component, backend, ccfg)
        if not specs then
          svc:obs_log('warn', {
            what = 'backend_observe_specs_failed',
            component = component,
            err = tostring(serr),
          })
          specs = {}
        end

        for _, spec in ipairs(specs) do
          if type(spec) == 'table'
            and type(spec.key) == 'string'
            and type(spec.topic) == 'table'
            and type(spec.on_event) == 'function'
          then
            if state.component_obs[spec.key] then
              state.component_obs[spec.key].watch:unwatch()
              svc:obs_log('warn', {
                what = 'duplicate_component_observer_key',
                key = spec.key,
                component = component,
              })
            end

            state.component_obs[spec.key] = {
              component = component,
              key = spec.key,
              topic = spec.topic,
              on_event = spec.on_event,
              watch = conn:watch_retained(spec.topic, {
                replay = true,
                queue_len = 16,
                full = 'drop_oldest',
              }),
            }
          end
        end
      end
    end
  end

  local create_ep = conn:bind(topics.manager_rpc('create-job'), { queue_len = 32 })
  local start_ep = conn:bind(topics.manager_rpc('start-job'), { queue_len = 32 })
  local commit_ep = conn:bind(topics.manager_rpc('commit-job'), { queue_len = 32 })
  local cancel_ep = conn:bind(topics.manager_rpc('cancel-job'), { queue_len = 32 })
  local retry_ep = conn:bind(topics.manager_rpc('retry-job'), { queue_len = 32 })
  local discard_ep = conn:bind(topics.manager_rpc('discard-job'), { queue_len = 32 })
  local get_ep = conn:bind(topics.manager_rpc('get-job'), { queue_len = 32 })
  local list_ep = conn:bind(topics.manager_rpc('list-jobs'), { queue_len = 32 })
  local ingest_create_ep = conn:bind(topics.ingest_rpc('create'), { queue_len = 32 })
  local ingest_append_ep = conn:bind(topics.ingest_rpc('append'), { queue_len = 32 })
  local ingest_commit_ep = conn:bind(topics.ingest_rpc('commit'), { queue_len = 32 })
  local ingest_abort_ep = conn:bind(topics.ingest_rpc('abort'), { queue_len = 32 })

  local endpoints = {
    create = create_ep,
    start = start_ep,
    commit = commit_ep,
    cancel = cancel_ep,
    retry = retry_ep,
    discard = discard_ep,
    get = get_ep,
    list = list_ep,
    ingest_create = ingest_create_ep,
    ingest_append = ingest_append_ep,
    ingest_commit = ingest_commit_ep,
    ingest_abort = ingest_abort_ep,
  }

  conn:retain(topics.manager_meta(), {
    owner = svc.name,
    interface = 'devicecode.cap/update-manager/1',
    methods = {
      ['create-job'] = true, ['start-job'] = true, ['commit-job'] = true,
      ['cancel-job'] = true, ['retry-job'] = true, ['discard-job'] = true,
      ['get-job'] = true, ['list-jobs'] = true,
    },
    events = { ['job-changed'] = true },
  })
  conn:retain(topics.manager_status(), { state = 'available' })
  conn:retain(topics.ingest_meta(), {
    owner = svc.name,
    interface = 'devicecode.cap/artifact-ingest/1',
    methods = { create = true, append = true, commit = true, abort = true },
    events = { ['instance-changed'] = true },
  })
  conn:retain(topics.ingest_status(), { state = 'available' })

  local function adopt_repo(new_repo)
    local loaded2, err = new_repo:load_all()
    if not loaded2 then
      svc:obs_log('warn', {
        what = 'repo_reload_failed',
        err = tostring(err),
      })
      return nil, err
    end

    repo = new_repo
    ctx.repo = repo
    ctx.save_job = function(job) return repo:save_job(job) end
    ctx.delete_job = function(job_id) return repo:delete_job(job_id) end
    ctx.flush_jobs = function() return flush_jobs(repo, state, on_store_error) end
    model.load_store(state, loaded2)
    model.mark_all_jobs_dirty(state)
    return true, nil
  end

  fibers.current_scope():finally(function()
    cfg_watch:unwatch()
    for _, rec in pairs(state.component_obs) do
      rec.watch:unwatch()
    end
    for id, rec in pairs(ctx.ingests or {}) do
      if rec.sink and rec.state == 'open' then pcall(function() rec.sink:abort() end) end
      conn:unretain(topics.workflow_ingest(id))
    end
    conn:unretain(topics.manager_meta())
    conn:unretain(topics.manager_status())
    conn:unretain(topics.ingest_meta())
    conn:unretain(topics.ingest_status())
    create_ep:unbind()
    start_ep:unbind()
    commit_ep:unbind()
    cancel_ep:unbind()
    retry_ep:unbind()
    discard_ep:unbind()
    get_ep:unbind()
    list_ep:unbind()
    ingest_create_ep:unbind()
    ingest_append_ep:unbind()
    ingest_commit_ep:unbind()
    ingest_abort_ep:unbind()
  end)

  rebuild_backends()
  rebuild_component_obs()
  model.adopt_persisted_jobs(state, now(), service_run_id)
  model.mark_all_jobs_dirty(state)
  local summary0 = projection.summary_payload(state)
  svc:running({
    jobs_total = summary0.counts and summary0.counts.total or 0,
    jobs_active = summary0.counts and summary0.counts.active or 0,
  })
  ctx.flush_publications()
  changed:signal()

  local seen = changed:version()

  while true do
    local active_join_op = runtime:active_join_op()
    local which, req, err = fibers.perform(
      next_update_event_op(state, cfg_watch, endpoints, runner_rx, changed, seen, active_join_op)
    )

    if which == 'changed' then
      seen = req or seen
      runtime:on_changed_tick()
      bundled:maybe_run()

    elseif which == 'ingest_create' then
      if not req then error('artifact-ingest create endpoint closed: ' .. tostring(err), 0) end
      commands:handle_ingest_create(req)

    elseif which == 'ingest_append' then
      if not req then error('artifact-ingest append endpoint closed: ' .. tostring(err), 0) end
      commands:handle_ingest_append(req)

    elseif which == 'ingest_commit' then
      if not req then error('artifact-ingest commit endpoint closed: ' .. tostring(err), 0) end
      commands:handle_ingest_commit(req)

    elseif which == 'ingest_abort' then
      if not req then error('artifact-ingest abort endpoint closed: ' .. tostring(err), 0) end
      commands:handle_ingest_abort(req)

    elseif which == 'runner' then
      runtime:handle_runner_event(req)

    elseif which == 'active_join' then
      runtime:handle_active_join(req)

    elseif type(which) == 'string' and state.component_obs[which] then
      local rec = state.component_obs[which]
      rec.on_event(ctx, rec, req)
      bundled:maybe_run()

    elseif which == 'cfg' then
      local ev = req
      if not ev then
        svc:failed(tostring(err or 'cfg_watch_closed'))
        error('update cfg watch closed: ' .. tostring(err), 0)
      end

      if ev.op == 'replay_done' then
        state.cfg_bootstrapped = true
        changed:signal()
      else
        local old_ns = state.cfg.jobs_namespace

        if ev.op == 'retain' then
          state.cfg = model.merge_cfg(ev.payload, SCHEMA)
        elseif ev.op == 'unretain' then
          state.cfg = model.default_cfg(SCHEMA)
        end

        rebuild_backends()
        rebuild_component_obs()

        local new_ns = state.cfg.jobs_namespace
        if new_ns ~= old_ns then
          if state.active_job or state.locks.global ~= nil then
            svc:obs_log('warn', {
              what = 'jobs_namespace_change_ignored_while_active',
              old = tostring(old_ns),
              new = tostring(new_ns),
            })
            state.cfg.jobs_namespace = old_ns
          else
            local new_repo = job_store.open(store_cap, { namespace = new_ns })
            local ok, aerr = adopt_repo(new_repo)
            if ok then
              model.adopt_persisted_jobs(state, now(), service_run_id)
            else
              state.cfg.jobs_namespace = old_ns
              svc:obs_log('warn', {
                what = 'repo_adopt_failed',
                err = tostring(aerr),
              })
            end
          end
        end

        bundled = bundled_reconcile_mod.new(ctx, commands)
        ctx.bundled = bundled
        ctx.on_job_succeeded = function(job, result)
          bundled:mark_job_success(job, result)
        end

        changed:signal()
      end

    elseif which == 'create' then
      if not req then
        error('update create endpoint closed: ' .. tostring(err), 0)
      end
      commands:handle_create(req)

    elseif which == 'start' then
      if not req then error('update start endpoint closed: ' .. tostring(err), 0) end
      commands:handle_method(req, 'start')
    elseif which == 'commit' then
      if not req then error('update commit endpoint closed: ' .. tostring(err), 0) end
      commands:handle_method(req, 'commit')
    elseif which == 'cancel' then
      if not req then error('update cancel endpoint closed: ' .. tostring(err), 0) end
      commands:handle_method(req, 'cancel')
    elseif which == 'retry' then
      if not req then error('update retry endpoint closed: ' .. tostring(err), 0) end
      commands:handle_method(req, 'retry')
    elseif which == 'discard' then
      if not req then error('update discard endpoint closed: ' .. tostring(err), 0) end
      commands:handle_method(req, 'discard')

    elseif which == 'get' then
      if not req then
        error('update get endpoint closed: ' .. tostring(err), 0)
      end
      commands:handle_get(req)

    elseif which == 'list' then
      if not req then
        error('update list endpoint closed: ' .. tostring(err), 0)
      end
      commands:handle_list(req)
    end
  end
end

return M
