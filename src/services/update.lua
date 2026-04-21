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
local component_backend_mod = require 'services.update.backends.component_proxy'
local cm5_backend_mod = require 'services.update.backends.cm5_swupdate'
local mcu_backend_mod = require 'services.update.backends.mcu_component'
local uuid        = require 'uuid'
local safe        = require 'coxpcall'

local M = {}
local SCHEMA = 'devicecode.config/update/1'

local function retain_best_effort(conn, topic, payload)
    safe.pcall(function() conn:retain(topic, payload) end)
end

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

    local function artifact_policy_for_component(component)
        return state.cfg.artifacts.policies[component] or state.cfg.artifacts.default_policy or 'prefer_durable'
    end

    local function artifact_snapshot(artefact)
        if type(artefact) ~= 'table' or type(artefact.describe) ~= 'function' then
            return nil, 'invalid_artefact'
        end
        local rec = artefact:describe()
        if type(rec) ~= 'table' then return nil, 'invalid_artefact_record' end
        return rec, nil
    end

    local function artifact_open(ref)
        local opts_ = assert(cap_sdk.args.new.ArtifactStoreOpenOpts(ref))
        local reply, err = artifact_cap:call_control('open', opts_)
        if not reply then return nil, err end
        if reply.ok ~= true then return nil, reply.reason end
        return reply.reason, nil
    end

    local function artifact_delete(ref)
        local opts_ = assert(cap_sdk.args.new.ArtifactStoreDeleteOpts(ref))
        local reply, err = artifact_cap:call_control('delete', opts_)
        if not reply then return nil, err end
        if reply.ok ~= true then return nil, reply.reason end
        return true, nil
    end

    local function artifact_import_path(path, component, metadata)
        local meta = { kind = 'update', component = component, metadata = metadata }
        local opts_ = assert(cap_sdk.args.new.ArtifactStoreImportPathOpts(path, meta, artifact_policy_for_component(component)))
        local reply, err = artifact_cap:call_control('import_path', opts_)
        if not reply then return nil, nil, err end
        if reply.ok ~= true then return nil, nil, reply.reason end
        local artefact = reply.reason
        local rec, rerr = artifact_snapshot(artefact)
        if not rec then return nil, nil, rerr end
        return artefact:ref(), rec, nil
    end

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

    local function flush_publications()
        store_sync.flush_jobs(repo, state, on_store_error)
        for _, id in ipairs(state.store.order) do
            local job = state.store.jobs[id]
            if job then
                retain_best_effort(conn, projection.job_topic(id), { job = projection.public_job(job) })
            end
        end
        if state.summary_dirty then
            retain_best_effort(conn, projection.summary_topic(), projection.summary_payload(state))
            model.set_summary_clean(state)
        end
    end

    local function publish_job_only(job)
        if not job then return end
        retain_best_effort(conn, projection.job_topic(job.job_id), { job = projection.public_job(job) })
    end

    local function patch_job(job, patch, opts_)
        opts_ = opts_ or {}
        model.patch_job(state, job, patch, now(), service_run_id, opts_)
        if not opts_.no_save then
            local ok, err = store_sync.save_job(repo, job)
            if not ok then on_store_error(job and job.job_id, err) end
        end
        if not opts_.no_signal then changed:signal() end
    end

    local function release_artifact_if_present(job)
        if not job or type(job.artifact_ref) ~= 'string' or job.artifact_ref == '' then return end
        local ref = job.artifact_ref
        local ok, err = artifact_delete(ref)
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

    local function build_job_artifact(payload)
        local component = assert(payload.component, 'component required')
        if not state.cfg.components[component] then return nil, nil, 'unknown_component' end

        local artifact_ref = payload.artifact_ref
        local artifact_meta = nil
        local source_kind = type(payload.source) == 'table' and payload.source.kind or nil
        if type(artifact_ref) == 'string' and artifact_ref ~= '' then
            local artefact, derr = artifact_open(artifact_ref)
            if not artefact then return nil, nil, derr end
            local desc, derr2 = artifact_snapshot(artefact)
            if not desc then return nil, nil, derr2 end
            artifact_meta = desc
        elseif type(payload.artifact) == 'string' and payload.artifact ~= '' then
            local ref, meta, ierr = artifact_import_path(payload.artifact, component, payload.metadata)
            if not ref then return nil, nil, ierr end
            artifact_ref, artifact_meta = ref, meta
        end
        if type(artifact_ref) ~= 'string' or artifact_ref == '' then
            if source_kind == 'upload' then return nil, nil, nil end
            return nil, nil, 'artifact_required'
        end
        return artifact_ref, artifact_meta, nil
    end

    local function create_job(payload)
        local component = assert(payload.component, 'component required')
        if not state.cfg.components[component] then return nil, 'unknown_component' end
        local source_kind = type(payload.source) == 'table' and payload.source.kind or nil
        local artifact_ref, artifact_meta, aerr = build_job_artifact(payload)
        if aerr ~= nil then return nil, aerr end
        if type(source_kind) ~= 'string' or source_kind == '' then
            source_kind = (artifact_ref and 'baked') or nil
        end
        if type(artifact_ref) ~= 'string' or artifact_ref == '' then
            if source_kind ~= 'upload' then return nil, 'artifact_required' end
            artifact_ref, artifact_meta = nil, nil
        end
        local job = model.create_job(state, {
            job_id = tostring(uuid.new()),
            offer_id = payload.offer_id,
            component = component,
            source_kind = source_kind,
            artifact_ref = artifact_ref,
            artifact_meta = artifact_meta,
            expected_version = payload.expected_version,
            metadata = type(payload.metadata) == 'table' and model.copy_value(payload.metadata) or nil,
            auto_start = (type(payload.options) == 'table' and payload.options.auto_start == true),
            auto_commit = (type(payload.options) == 'table' and payload.options.auto_commit == true),
        }, now(), service_run_id)
        local ok, err = store_sync.save_job(repo, job)
        if not ok then return nil, err end
        changed:signal()
        return job, nil
    end

    local function clone_job_for_retry(src)
        local job, err = create_job({
            component = src.component,
            offer_id = src.offer_id,
            artifact_ref = src.artifact_ref,
            expected_version = src.expected_version,
            metadata = model.copy_value(src.metadata),
        })
        if not job then return nil, err end
        patch_job(src, { state = 'superseded', next_step = nil, error = nil })
        return job, nil
    end

    local function release_active(job_id)
        local job = state.store.jobs[job_id]
        model.release_lock(state, job, now(), service_run_id)
        if state.active_job and state.active_job.job_id == job_id then
            model.clear_active_job(state)
        end
        if job then
            local ok, err = store_sync.save_job(repo, job)
            if not ok then on_store_error(job_id, err) end
        end
    end

    local function spawn_runner(mode, job)
        local backend = state.backends[job.component]
        if not backend then return nil, 'backend_missing' end
        local child, err = service_scope:child()
        if not child then return nil, err end
        local stage_source = nil
        if mode == 'stage' then
            local component_cfg = state.cfg.components[job.component]
            if type(component_cfg) == 'table' and component_cfg.backend == 'mcu_component' then
                if type(job.artifact_ref) ~= 'string' or job.artifact_ref == '' then
                    return nil, 'missing_artifact_ref'
                end
                local opened, oerr = artifact_open(job.artifact_ref)
                if not opened then return nil, oerr or 'artifact_open_failed' end
                stage_source = opened
            end
        end
        model.acquire_lock(state, job, now(), service_run_id)
        local ok, save_err = store_sync.save_job(repo, job)
        if not ok then on_store_error(job.job_id, save_err) end
        local cfg_reconcile = state.cfg.reconcile
        local snapshot = copy_job(job)
        local spawned, spawn_err = child:spawn(function()
            if mode == 'stage' then
                return runner.run_stage(conn, snapshot, backend, runner_tx, stage_source)
            elseif mode == 'commit' then
                return runner.run_commit(conn, snapshot, backend, runner_tx, cfg_reconcile)
            else
                return runner.run_reconcile(conn, snapshot, backend, runner_tx, cfg_reconcile, observer)
            end
        end)
        if not spawned then
            model.release_lock(state, job, now(), service_run_id)
            local ok2, err2 = store_sync.save_job(repo, job)
            if not ok2 then on_store_error(job.job_id, err2) end
            return nil, spawn_err
        end
        model.set_active_job(state, { job_id = job.job_id, scope = child, component = job.component, started_at = now(), mode = mode })
        changed:signal()
        return true, nil
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
    flush_publications()
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
        if state.active_job then
            ops.active_join = state.active_job.scope:join_op():wrap(function(st, _report, primary)
                return { job_id = state.active_job.job_id, st = st, primary = primary }
            end)
        end
        local which, req, err = fibers.perform(fibers.named_choice(ops))

        if which == 'changed' then
            flush_publications()
            local resumable = model.select_resumable_job(state)
            if resumable then
                local ok, rerr = spawn_runner('reconcile', resumable)
                if not ok then svc:obs_log('warn', { what = 'adopted_job_resume_failed', job_id = resumable.job_id, err = tostring(rerr) }) end
            end
        elseif which == 'runner' then
            local ev = req
            if ev and ev.job_id then
                local job = state.store.jobs[ev.job_id]
                if job then
                    if ev.tag == 'failed' then
                        patch_job(job, { state = 'failed', stage = 'failed', error = tostring(ev.err or 'failed'), next_step = nil })
                        release_artifact_if_present(job)
                    elseif ev.tag == 'staged' then
                        if ev.pre_commit_incarnation ~= nil then job.pre_commit_incarnation = ev.pre_commit_incarnation end
                        if ev.pre_commit_boot_id ~= nil then job.pre_commit_boot_id = ev.pre_commit_boot_id end
                        patch_job(job, {
                            state = 'awaiting_commit',
                            stage = 'staged_on_mcu',
                            next_step = 'commit',
                            result = ev.staged,
                            staged_meta = ev.staged,
                            error = nil,
                        })
                        if type(ev.staged) == 'table' and ev.staged.artifact_retention == 'release' then
                            release_artifact_if_present(job)
                        end
                    elseif ev.tag == 'commit_started' then
                        patch_job(job, {
                            state = 'awaiting_return',
                            stage = 'awaiting_member_return',
                            result = ev.result,
                            error = nil,
                            next_step = 'reconcile',
                        }, { runtime_merge = {
                            awaiting_return_run_id = service_run_id,
                            awaiting_return_mono = now(),
                        } })
                    elseif ev.tag == 'reconciled_success' then
                        patch_job(job, {
                            state = 'succeeded',
                            stage = 'succeeded',
                            result = ev.result,
                            error = nil,
                            next_step = nil,
                            post_commit_incarnation = ev.result and ev.result.incarnation or nil,
                        })
                        release_artifact_if_present(job)
                    elseif ev.tag == 'reconciled_failure' then
                        patch_job(job, {
                            state = 'failed',
                            stage = 'failed',
                            result = ev.result,
                            error = tostring(ev.err or 'failed'),
                            next_step = nil,
                        })
                    elseif ev.tag == 'reconcile_progress' then
                        patch_job(job, {
                            state = 'awaiting_return',
                            stage = 'verifying_postboot',
                            result = ev.result,
                            error = nil,
                            next_step = 'reconcile',
                        }, { runtime_merge = {
                            awaiting_return_run_id = service_run_id,
                            awaiting_return_mono = now(),
                        } })
                    elseif ev.tag == 'timed_out' then
                        patch_job(job, {
                            state = 'timed_out',
                            stage = 'timed_out',
                            result = nil,
                            error = tostring(ev.err or 'timeout'),
                            next_step = nil,
                        })
                    end
                end
            end
        elseif which == 'active_join' then
            local ev = req
            local job = ev and state.store.jobs[ev.job_id] or nil
            local current_active = state.active_job and state.active_job.job_id or nil
            if ev then release_active(ev.job_id) end
            if ev and job and current_active == ev.job_id then
                if ev.st == 'failed' and not model.is_terminal(job.state) then
                    patch_job(job, { state = 'failed', stage = 'failed', error = tostring(ev.primary or 'worker_failed'), next_step = nil })
                elseif ev.st == 'cancelled' and not model.is_terminal(job.state) then
                    patch_job(job, { state = 'cancelled', stage = 'failed', error = tostring(ev.primary or 'worker_cancelled'), next_step = nil })
                elseif ev.st == 'ok' and job.state == 'awaiting_commit' and job.auto_commit then
                    local ok3, aerr3 = model.can_activate(state, job)
                    if ok3 then
                        patch_job(job, { state = 'awaiting_return', stage = 'commit_sent', next_step = 'reconcile', error = nil }, { runtime_merge = { awaiting_return_run_id = service_run_id, awaiting_return_mono = now() } })
                        store_sync.flush_jobs(repo, state, on_store_error)
                        local wok, werr = spawn_runner('commit', job)
                        if not wok then patch_job(job, { state = 'failed', stage = 'failed', error = tostring(werr), next_step = nil }) end
                    else
                        patch_job(job, { state = 'failed', stage = 'failed', error = tostring(aerr3 or 'auto_commit_blocked'), next_step = nil })
                    end
                elseif ev.st == 'ok' and job.state == 'awaiting_return' and job.next_step == 'reconcile' then
                    local wok, werr = spawn_runner('reconcile', job)
                    if not wok then
                        patch_job(job, { state = 'failed', stage = 'failed', error = tostring(werr or 'reconcile_spawn_failed'), next_step = nil })
                    end
                end
            end
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
                publish_job_only(job)
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
            local payload = req.payload or {}
            local job, jerr = create_job(payload)
            if not job then
                req:fail(jerr)
            else
                local reply = { ok = true, job = projection.public_job(job) }
                if job.source_kind == 'upload' and (type(job.artifact_ref) ~= 'string' or job.artifact_ref == '') then
                    reply.upload = { required = true }
                end
                req:reply(reply)
            end
        elseif which == 'job_do' then
            if not req then error('update job do endpoint closed: ' .. tostring(err), 0) end
            local payload = req.payload or {}
            local op = payload.op
            local job = state.store.jobs[payload.job_id]
            if type(op) ~= 'string' or op == '' then
                req:fail('invalid_op')
            elseif not job then
                req:fail('unknown_job')
            elseif op == 'start' then
                if job.state ~= 'created' then
                    req:fail('job_not_startable')
                else
                    local ok, aerr = model.can_activate(state, job)
                    if not ok then
                        req:fail(aerr)
                    else
                        patch_job(job, { state = 'staging', stage = 'validating_artifact', next_step = 'stage', error = nil })
                        local wok, werr = spawn_runner('stage', job)
                        if not wok then
                            patch_job(job, { state = 'failed', stage = 'failed', error = tostring(werr), next_step = nil })
                            req:fail(tostring(werr))
                        else
                            req:reply({ ok = true, job = projection.public_job(job) })
                        end
                    end
                end
            elseif op == 'commit' then
                if job.state ~= 'awaiting_commit' then
                    req:fail('job_not_committable')
                else
                    local ok, aerr = model.can_activate(state, job)
                    if not ok then
                        req:fail(aerr)
                    else
                        patch_job(job, { state = 'awaiting_return', stage = 'commit_sent', next_step = 'reconcile', error = nil }, { runtime_merge = {
                            awaiting_return_run_id = service_run_id,
                            awaiting_return_mono = now(),
                        } })
                        -- Persist durable pre-commit handoff before destructive commit may occur.
                        store_sync.flush_jobs(repo, state, on_store_error)
                        local wok, werr = spawn_runner('commit', job)
                        if not wok then
                            patch_job(job, { state = 'failed', stage = 'failed', error = tostring(werr), next_step = nil })
                            req:fail(tostring(werr))
                        else
                            req:reply({ ok = true, job = projection.public_job(job) })
                        end
                    end
                end
            elseif op == 'upload_progress' then
                if job.state ~= 'created' or (type(job.artifact_ref) == 'string' and job.artifact_ref ~= '') then
                    req:fail('job_not_uploadable')
                else
                    job.stage = 'uploading_to_cm5'
                    job.runtime = type(job.runtime) == 'table' and job.runtime or {}
                    job.runtime.progress = job.runtime.progress or {}
                    local sent = tonumber(payload.sent) or 0
                    local total = tonumber(payload.total)
                    local pct = (total and total > 0) and (sent * 100.0 / total) or nil
                    job.runtime.progress.upload = { sent = sent, total = total, pct = pct }
                    publish_job_only(job)
                    req:reply({ ok = true, job = projection.public_job(job) })
                end
            elseif op == 'upload_failed' then
                if job.state ~= 'created' then
                    req:fail('job_not_uploadable')
                else
                    patch_job(job, { state = 'failed', stage = 'failed', error = tostring(payload.error or 'upload_failed'), next_step = nil })
                    req:reply({ ok = true, job = projection.public_job(job) })
                end
            elseif op == 'attach_artifact' then
                if job.state ~= 'created' or (type(job.artifact_ref) == 'string' and job.artifact_ref ~= '') then
                    req:fail('job_not_attachable')
                elseif type(payload.artifact_ref) ~= 'string' or payload.artifact_ref == '' then
                    req:fail('invalid_artifact_ref')
                else
                    job.artifact_ref = payload.artifact_ref
                    job.artifact_meta = payload.artifact_meta
                    job.stage = 'uploaded_to_cm5'
                    job.next_step = nil
                    job.runtime = type(job.runtime) == 'table' and job.runtime or {}
                    job.runtime.progress = job.runtime.progress or {}
                    local auto_start = payload.auto_start
                    if auto_start == nil then auto_start = job.auto_start end
                    if auto_start then
                        patch_job(job, { state = 'staging', stage = 'validating_artifact', next_step = 'stage', error = nil })
                        local wok, werr = spawn_runner('stage', job)
                        if not wok then
                            patch_job(job, { state = 'failed', stage = 'failed', error = tostring(werr), next_step = nil })
                            req:fail(tostring(werr))
                        else
                            req:reply({ ok = true, job = projection.public_job(job) })
                        end
                    else
                        local ok, serr2 = store_sync.save_job(repo, job)
                        if not ok then on_store_error(job.job_id, serr2) end
                        model.mark_job_dirty(state, job.job_id)
                        changed:signal()
                        req:reply({ ok = true, job = projection.public_job(job) })
                    end
                end
            elseif op == 'cancel' then
                if model.ACTIVE_STATES[job.state] then
                    req:fail('job_active')
                elseif model.TERMINAL_STATES[job.state] then
                    req:fail('job_terminal')
                elseif job.state ~= 'created' and job.state ~= 'awaiting_commit' then
                    req:fail('job_not_cancellable')
                else
                    patch_job(job, { state = 'cancelled', next_step = nil, error = nil })
                    req:reply({ ok = true, job = projection.public_job(job) })
                end
            elseif op == 'retry' then
                if not model.job_actions(job).retry then
                    req:fail('job_not_retryable')
                else
                    local new_job, rerr = clone_job_for_retry(job)
                    if not new_job then req:fail(rerr) else req:reply({ ok = true, job = projection.public_job(new_job) }) end
                end
            elseif op == 'discard' then
                if not model.is_terminal(job.state) then
                    req:fail('job_not_discardable')
                else
                    if type(job.artifact_ref) == 'string' and job.artifact_ref ~= '' then
                        release_artifact_if_present(job)
                    end
                    local _ = store_sync.delete_job(repo, job.job_id)
                    model.remove_job(state, job.job_id)
                    safe.pcall(function() conn:unretain(projection.job_topic(job.job_id)) end)
                    changed:signal()
                    req:reply({ ok = true })
                end
            else
                req:fail('invalid_op')
            end
        elseif which == 'get' then
            if not req then error('update get endpoint closed: ' .. tostring(err), 0) end
            local payload = req.payload or {}
            local job = state.store.jobs[payload.job_id]
            if not job then req:fail('unknown_job') else req:reply({ ok = true, job = projection.public_job(job) }) end
        elseif which == 'list' then
            if not req then error('update list endpoint closed: ' .. tostring(err), 0) end
            req:reply({ ok = true, jobs = projection.public_jobs(state) })
        end
    end
end

return M
