local fibers      = require 'fibers'
local pulse       = require 'fibers.pulse'
local mailbox     = require 'fibers.mailbox'
local base        = require 'devicecode.service_base'
local cap_sdk     = require 'services.hal.sdk.cap'
local job_store   = require 'services.update.job_store'
local model       = require 'services.update.model'
local projection  = require 'services.update.projection'
local store_sync  = require 'services.update.store_sync'
local reconcile   = require 'services.update.reconcile'
local observe_mod = require 'services.update.observe'
local runner      = require 'services.update.runner'
local publish_mod = require 'services.update.publish'
local runtime_mod = require 'services.update.runtime'
local commands_mod = require 'services.update.commands'
local component_backend_mod = require 'services.update.backends.component_proxy'
local cm5_backend_mod = require 'services.update.backends.cm5_swupdate'
local mcu_backend_mod = require 'services.update.backends.mcu_component'
local uuid        = require 'uuid'
local safe        = require 'coxpcall'

local M = {}
local SCHEMA = 'devicecode.config/update/1'

local function build_backend(component, component_cfg)
    local opts = { component = component, proxy_mod = component_backend_mod }
    if type(component_cfg) == 'table' then
        for k, v in pairs(component_cfg) do
            if k ~= 'backend' and opts[k] == nil then opts[k] = v end
        end
    end
    if component_cfg.backend == 'cm5_swupdate' then
        return cm5_backend_mod.new(opts)
    end
    if component_cfg.backend == 'mcu_component' then
        return mcu_backend_mod.new(opts)
    end
    return nil, 'unknown_backend:' .. tostring(component_cfg.backend)
end

local function discover_cap(conn, class, id, timeout)
    local listener = cap_sdk.new_cap_listener(conn, class, id)
    local cap, err = listener:wait_for_cap({ timeout = timeout or 30.0 })
    listener:close()
    return cap, err
end

local function copy_job(job)
    return model.copy_value(job)
end

function M.start(conn, opts)
    opts = opts or {}
    local service_scope = assert(fibers.current_scope())
    local svc = base.new(conn, { name = opts.name or 'update', env = opts.env })
    local heartbeat_s = (type(opts.heartbeat_s) == 'number') and opts.heartbeat_s or 30.0
    svc:spawn_heartbeat(heartbeat_s, 'tick')
    svc:status('starting')

    local store_cap, serr = discover_cap(conn, 'control_store', 'update', 30.0)
    if serr ~= '' or not store_cap then
        svc:status('failed', { reason = tostring(serr or 'control_store capability not found') })
        error('update: failed to discover control_store/update capability: ' .. tostring(serr), 0)
    end

    local artifact_cap, aerr = discover_cap(conn, 'artifact_store', 'main', 30.0)
    if aerr ~= '' or not artifact_cap then
        svc:status('failed', { reason = tostring(aerr or 'artifact_store capability not found') })
        error('update: failed to discover artifact_store/main capability: ' .. tostring(aerr), 0)
    end

    local cfg_watch = conn:watch_retained({ 'cfg', 'update' }, { replay = true, queue_len = 8, full = 'drop_oldest' })
    local cfg = model.default_cfg(SCHEMA)
    local repo = job_store.open(store_cap, { namespace = cfg.jobs_namespace })
    local loaded, lerr = store_sync.load(repo)
    if not loaded then
        svc:status('failed', { reason = tostring(lerr) })
        error('update: failed to load job store: ' .. tostring(lerr), 0)
    end

    local state = model.new_state(cfg)
    model.load_store(state, loaded)

    local changed = pulse.scoped({ close_reason = 'update service stopping' })
    local observer = observe_mod.new()
    local service_run_id = tostring(uuid.new())
    local runner_tx, runner_rx = mailbox.new(64, { full = 'drop_oldest' })

    local function now() return svc:now() end

    local function on_store_error(job_id, err)
        svc:obs_log('error', { what = 'job_save_failed', err = tostring(err), job_id = job_id })
    end

    local ctx = {
        conn = conn,
        state = state,
        model = model,
        projection = projection,
        store_sync = store_sync,
        repo = repo,
        artifact_cap = artifact_cap,
        service_scope = service_scope,
        service_run_id = service_run_id,
        now = now,
        changed = changed,
        observer = observer,
        runner = runner,
        runner_tx = runner_tx,
        on_store_error = on_store_error,
        copy_job = copy_job,
    }

    local function patch_job(job, patch, opts_)
        opts_ = opts_ or {}
        model.patch_job(state, job, patch, now(), service_run_id, opts_)
        if not opts_.no_save then
            local ok, err = store_sync.save_job(repo, job)
            if not ok then on_store_error(job and job.job_id, err) end
        end
        if not opts_.no_signal then changed:signal() end
    end
    ctx.patch_job = patch_job

    local commands = commands_mod.new(ctx)
    ctx.artifact_open = function(...) return commands:artifact_open(...) end

    local function release_artifact_if_present(job)
        if not job or type(job.artifact_ref) ~= 'string' or job.artifact_ref == '' then return end
        local ref = job.artifact_ref
        local ok, err = commands:artifact_delete(ref)
        if not ok and err ~= 'not_found' then
            svc:obs_log('warn', { what = 'artifact_delete_failed', artifact_ref = ref, err = tostring(err) })
            return
        end
        job.artifact_ref = nil
        job.artifact_released_at = now()
        model.touch_job(state, job, now(), service_run_id, false, nil)
        local sok, serr2 = store_sync.save_job(repo, job)
        if not sok then on_store_error(job.job_id, serr2) end
        model.mark_job_dirty(state, job.job_id)
        changed:signal()
    end
    ctx.release_artifact_if_present = release_artifact_if_present

    local publisher = publish_mod.new(ctx)
    ctx.publisher = publisher
    local runtime = runtime_mod.new(ctx)
    ctx.runtime = runtime

    local function rebuild_backends()
        state.backends = {}
        for component, ccfg in pairs(state.cfg.components) do
            local backend, berr = build_backend(component, ccfg)
            if backend then
                state.backends[component] = backend
            else
                svc:obs_log('warn', { what = 'backend_build_failed', component = component, err = tostring(berr) })
            end
        end
    end

    local function rebuild_component_obs()
        for _, rec in pairs(state.component_obs) do
            pcall(function() rec.watch:unwatch() end)
        end
        state.component_obs = {}
        for component, ccfg in pairs(state.cfg.components) do
            local cwatch = conn:watch_retained({ 'state', 'device', 'component', component }, { replay = true, queue_len = 16, full = 'drop_oldest' })
            state.component_obs['comp:' .. component] = { kind = 'component', component = component, watch = cwatch }
            local transfer = type(ccfg) == 'table' and ccfg.transfer or nil
            local link_id = type(transfer) == 'table' and transfer.link_id or nil
            if type(link_id) == 'string' and link_id ~= '' then
                local watch = conn:watch_retained({ 'state', 'fabric', 'link', link_id, 'transfer' }, { replay = true, queue_len = 16, full = 'drop_oldest' })
                state.component_obs['xfer:' .. component] = { kind = 'transfer', component = component, link_id = link_id, watch = watch }
            end
        end
    end

    local create_ep = conn:bind({ 'cmd', 'update', 'job', 'create' }, { queue_len = 32 })
    local do_ep = conn:bind({ 'cmd', 'update', 'job', 'do' }, { queue_len = 32 })
    local get_ep = conn:bind({ 'cmd', 'update', 'job', 'get' }, { queue_len = 32 })
    local list_ep = conn:bind({ 'cmd', 'update', 'job', 'list' }, { queue_len = 32 })

    local function adopt_repo(new_repo)
        local loaded2, err = store_sync.load(new_repo)
        if not loaded2 then
            svc:obs_log('warn', { what = 'repo_reload_failed', err = tostring(err) })
            return nil, err
        end
        repo = new_repo
        ctx.repo = repo
        model.load_store(state, loaded2)
        model.mark_all_jobs_dirty(state)
        return true, nil
    end

    fibers.current_scope():finally(function()
        safe.pcall(function() create_ep:unbind() end)
        safe.pcall(function() do_ep:unbind() end)
        safe.pcall(function() get_ep:unbind() end)
        safe.pcall(function() list_ep:unbind() end)
    end)

    rebuild_backends()
    rebuild_component_obs()
    reconcile.normalise_persisted(state, now(), service_run_id, model)
    model.mark_all_jobs_dirty(state)
    publisher:flush_publications()
    changed:signal()
    svc:status('running')

    local seen = changed:version()
    while true do
        local ops = {
            cfg = cfg_watch:recv_op(),
            create = create_ep and create_ep:recv_op() or nil,
            job_do = do_ep and do_ep:recv_op() or nil,
            get = get_ep and get_ep:recv_op() or nil,
            list = list_ep and list_ep:recv_op() or nil,
            runner = runner_rx:recv_op(),
            changed = changed:changed_op(seen):wrap(function(ver) seen = ver; return ver end),
        }
        for key, rec in pairs(state.component_obs) do
            ops[key] = rec.watch:recv_op()
        end
        local active_join_op = runtime:active_join_op()
        if active_join_op then
            ops.active_join = active_join_op
        end

        local which, req, err = fibers.perform(fibers.named_choice(ops))

        if which == 'changed' then
            publisher:flush_publications()
            local resumable = model.select_resumable_job(state)
            if resumable then
                local ok, rerr = runtime:spawn_runner('reconcile', resumable)
                if not ok then svc:obs_log('warn', { what = 'adopted_job_resume_failed', job_id = resumable.job_id, err = tostring(rerr) }) end
            end
        elseif which == 'runner' then
            runtime:handle_runner_event(req)
        elseif which == 'active_join' then
            runtime:handle_active_join(req)
        elseif type(which) == 'string' and state.component_obs[which] then
            local rec = state.component_obs[which]
            local ev = req
            local job = state.active_job and state.store.jobs[state.active_job.job_id] or nil
            if rec and rec.kind == 'component' then
                if type(ev) == 'table' and ev.op == 'retain' and type(ev.payload) == 'table' then
                    observer:note_component(rec.component, ev.payload)
                elseif type(ev) == 'table' and ev.op == 'unretain' then
                    observer:clear_component(rec.component)
                end
            elseif rec and rec.kind == 'transfer' and job and job.component == rec.component and job.state == 'staging' and type(ev) == 'table' and ev.op == 'retain' and type(ev.payload) == 'table' then
                local status = ev.payload.status or {}
                local sent = tonumber(status.offset) or 0
                local total = tonumber(status.size) or nil
                local pct = (total and total > 0) and (sent * 100.0 / total) or nil
                job.runtime = type(job.runtime) == 'table' and job.runtime or {}
                job.runtime.progress = job.runtime.progress or {}
                job.runtime.progress.transfer = { sent = sent, total = total, pct = pct }
                local tstate = tostring(status.state or '')
                if tstate == 'done' then
                    job.stage = 'staged_on_mcu'
                elseif tstate ~= '' and tstate ~= 'idle' then
                    job.stage = 'transferring_to_mcu'
                end
                publisher:publish_job_only(job)
            end
        elseif which == 'cfg' then
            local ev = req
            if not ev then
                svc:status('failed', { reason = tostring(err or 'cfg_watch_closed') })
                error('update cfg watch closed: ' .. tostring(err), 0)
            end
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
                    svc:obs_log('warn', { what = 'jobs_namespace_change_ignored_while_active', old = tostring(old_ns), new = tostring(new_ns) })
                    state.cfg.jobs_namespace = old_ns
                else
                    local new_repo = job_store.open(store_cap, { namespace = new_ns })
                    local ok, aerr = adopt_repo(new_repo)
                    if ok then
                        reconcile.normalise_persisted(state, now(), service_run_id, model)
                    else
                        svc:obs_log('warn', { what = 'repo_adopt_failed', err = tostring(aerr) })
                    end
                end
            end
            changed:signal()
        elseif which == 'create' then
            if not req then error('update create endpoint closed: ' .. tostring(err), 0) end
            commands:handle_create(req)
        elseif which == 'job_do' then
            if not req then error('update job do endpoint closed: ' .. tostring(err), 0) end
            commands:handle_do(req)
        elseif which == 'get' then
            if not req then error('update get endpoint closed: ' .. tostring(err), 0) end
            commands:handle_get(req)
        elseif which == 'list' then
            if not req then error('update list endpoint closed: ' .. tostring(err), 0) end
            commands:handle_list(req)
        end
    end
end

return M
