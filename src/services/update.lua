local fibers    = require 'fibers'
local sleep     = require 'fibers.sleep'
local pulse     = require 'fibers.pulse'
local base      = require 'devicecode.service_base'
local cap_sdk   = require 'services.hal.sdk.cap'
local job_store = require 'services.update.job_store'
local component_backend_mod = require 'services.update.backends.component_proxy'
local cm5_backend_mod = require 'services.update.backends.cm5_swupdate'
local mcu_backend_mod = require 'services.update.backends.mcu_component'
local uuid      = require 'uuid'
local safe      = require 'coxpcall'

local M = {}
local SCHEMA = 'devicecode.config/update/1'

local ACTIVE_STATES = {
    staging = true,
    awaiting_return = true,
}

local TERMINAL_STATES = {
    succeeded = true,
    failed = true,
    rolled_back = true,
    cancelled = true,
    timed_out = true,
    superseded = true,
    discarded = true,
}

local PASSIVE_STATES = {
    created = true,
    awaiting_commit = true,
}

local function retain_best_effort(conn, topic, payload)
    safe.pcall(function() conn:retain(topic, payload) end)
end

local function job_topic(id)
    return { 'state', 'update', 'jobs', id }
end

local function summary_topic()
    return { 'state', 'update', 'summary' }
end

local function default_cfg()
    return {
        schema = SCHEMA,
        jobs_namespace = 'update/jobs',
        reconcile = {
            interval_s = 10.0,
            timeout_s = 180.0,
        },
        artifacts = {
            default_policy = 'transient_only',
            policies = {
                cm5 = 'transient_only',
                mcu = 'transient_only',
            },
        },
        components = {
            cm5 = { backend = 'cm5_swupdate' },
            mcu = { backend = 'mcu_component' },
        },
        admission = {
            mode = 'global_single',
        },
    }
end

local function merge_cfg(payload)
    local cfg = default_cfg()
    local data = payload and (payload.data or payload) or nil
    if type(data) ~= 'table' then return cfg end
    if data.schema ~= nil and data.schema ~= SCHEMA then return cfg end

    if type(data.jobs_namespace) == 'string' and data.jobs_namespace ~= '' then
        cfg.jobs_namespace = data.jobs_namespace
    end

    if type(data.reconcile) == 'table' then
        if type(data.reconcile.interval_s) == 'number' and data.reconcile.interval_s > 0 then
            cfg.reconcile.interval_s = data.reconcile.interval_s
        end
        if type(data.reconcile.timeout_s) == 'number' and data.reconcile.timeout_s > 0 then
            cfg.reconcile.timeout_s = data.reconcile.timeout_s
        end
    end

    if type(data.artifacts) == 'table' then
        if type(data.artifacts.default_policy) == 'string' and data.artifacts.default_policy ~= '' then
            cfg.artifacts.default_policy = data.artifacts.default_policy
        end
        if type(data.artifacts.policies) == 'table' then
            for component, policy in pairs(data.artifacts.policies) do
                if type(component) == 'string' and type(policy) == 'string' and policy ~= '' then
                    cfg.artifacts.policies[component] = policy
                end
            end
        end
    end

    if type(data.components) == 'table' then
        cfg.components = {}
        for component, spec in pairs(data.components) do
            if type(component) == 'string' and type(spec) == 'table' then
                local backend = type(spec.backend) == 'string' and spec.backend or nil
                if backend and backend ~= '' then
                    cfg.components[component] = { backend = backend }
                end
            end
        end
    end

    if type(data.admission) == 'table' and type(data.admission.mode) == 'string' and data.admission.mode ~= '' then
        cfg.admission.mode = data.admission.mode
    end

    return cfg
end

local function copy_value(v, seen)
    if type(v) ~= 'table' then return v end
    seen = seen or {}
    if seen[v] then return seen[v] end
    local out = {}
    seen[v] = out
    for k, vv in pairs(v) do out[copy_value(k, seen)] = copy_value(vv, seen) end
    return out
end

local function copy_job(job)
    return copy_value(job)
end

local function job_actions(job)
    local st = job and job.state or nil
    local has_retry_artifact = type(job) == 'table' and type(job.artifact_ref) == 'string' and job.artifact_ref ~= ''
    return {
        start = (st == 'created'),
        commit = (st == 'awaiting_commit'),
        cancel = (st == 'created' or st == 'awaiting_commit'),
        retry = has_retry_artifact and (st == 'failed' or st == 'rolled_back' or st == 'timed_out' or st == 'cancelled'),
        discard = TERMINAL_STATES[st] == true,
    }
end

local function public_job(job)
    local staged_meta = type(job.staged_meta) == 'table' and job.staged_meta or nil
    return {
        job_id = job.job_id,
        component = job.component,
        source = {
            offer_id = job.offer_id,
        },
        artifact = {
            ref = job.artifact_ref,
            meta = copy_value(job.artifact_meta),
            expected_version = job.expected_version,
            released_at = job.artifact_released_at,
            retention = staged_meta and staged_meta.artifact_retention or nil,
        },
        lifecycle = {
            state = job.state,
            next_step = job.next_step,
            created_seq = job.created_seq,
            updated_seq = job.updated_seq,
            created_mono = job.created_mono,
            updated_mono = job.updated_mono,
            error = job.error,
        },
        observation = {
            pre_commit_incarnation = job.pre_commit_incarnation,
            post_commit_incarnation = job.post_commit_incarnation,
        },
        actions = job_actions(job),
        result = copy_value(job.result),
        metadata = copy_value(job.metadata),
    }
end

local function public_jobs(store)
    local jobs = {}
    for _, id in ipairs(store.order) do
        local job = store.jobs[id]
        if job then jobs[#jobs + 1] = public_job(job) end
    end
    return jobs
end

local function sort_store(store)
    table.sort(store.order, function(a, b)
        local ja, jb = store.jobs[a], store.jobs[b]
        local ta = (ja and (ja.created_seq or ja.created_mono)) or 0
        local tb = (jb and (jb.created_seq or jb.created_mono)) or 0
        if ta == tb then return tostring(a) < tostring(b) end
        return ta < tb
    end)
end

local function build_backend(component, component_cfg)
    local opts = { component = component, proxy_mod = component_backend_mod }
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
    local cfg = default_cfg()
    local repo = job_store.open(store_cap, { namespace = cfg.jobs_namespace })
    local store, lerr = repo:load_all()
    if not store then
        svc:status('failed', { reason = tostring(lerr) })
        error('update: failed to load job store: ' .. tostring(lerr), 0)
    end

    local changed = pulse.scoped({ close_reason = 'update service stopping' })
    local service_run_id = tostring(uuid.new())
    local active_job = nil
    local locks = { global = nil, component = {} }
    local backends = {}
    local dirty_jobs = {}
    local summary_dirty = false
    local seq = 0

    local function next_seq()
        seq = seq + 1
        return seq
    end

    local function seed_seq_from_store()
        local maxv = 0
        for _, id in ipairs(store.order) do
            local job = store.jobs[id]
            if job then
                if type(job.created_seq) == 'number' and job.created_seq > maxv then maxv = job.created_seq end
                if type(job.updated_seq) == 'number' and job.updated_seq > maxv then maxv = job.updated_seq end
            end
        end
        seq = maxv
    end

    local function mark_job_dirty(job_id)
        if type(job_id) == 'string' and job_id ~= '' then dirty_jobs[job_id] = true end
        summary_dirty = true
    end

    local function mark_all_jobs_dirty()
        for _, id in ipairs(store.order) do dirty_jobs[id] = true end
        summary_dirty = true
    end

    local function flush_publications()
        local flushed = false
        for _, id in ipairs(store.order) do
            if dirty_jobs[id] then
                local job = store.jobs[id]
                if job then
                    retain_best_effort(conn, job_topic(job.job_id), {
                        kind = 'update.job',
                        ts = svc:now(),
                        job = public_job(job),
                    })
                end
                dirty_jobs[id] = nil
                flushed = true
            end
        end
        if summary_dirty then
            local counts = {}
            for _, id in ipairs(store.order) do
                local job = store.jobs[id]
                if job then counts[job.state] = (counts[job.state] or 0) + 1 end
            end
            local active = {}
            if active_job then
                active[1] = {
                    job_id = active_job.job_id,
                    component = active_job.component,
                    started_at = active_job.started_at,
                }
            end
            retain_best_effort(conn, summary_topic(), {
                kind = 'update.summary',
                ts = svc:now(),
                count = #store.order,
                states = counts,
                active = active,
                locks = copy_value(locks),
            })
            summary_dirty = false
            flushed = true
        end
        return flushed
    end

    local function is_terminal(state)
        return TERMINAL_STATES[state] == true
    end

    local function is_active(state)
        return ACTIVE_STATES[state] == true
    end

    local function artifact_policy_for_component(component)
        return cfg.artifacts.policies[component] or cfg.artifacts.default_policy or 'prefer_durable'
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
        local opts = assert(cap_sdk.args.new.ArtifactStoreOpenOpts(ref))
        local reply, err = artifact_cap:call_control('open', opts)
        if not reply then return nil, err end
        if reply.ok ~= true then return nil, reply.reason end
        return reply.reason, nil
    end

    local function artifact_delete(ref)
        local opts = assert(cap_sdk.args.new.ArtifactStoreDeleteOpts(ref))
        local reply, err = artifact_cap:call_control('delete', opts)
        if not reply then return nil, err end
        if reply.ok ~= true then return nil, reply.reason end
        return true, nil
    end

    local function artifact_import_path(path, component, metadata)
        local meta = { kind = 'update', component = component, metadata = metadata }
        local opts = assert(cap_sdk.args.new.ArtifactStoreImportPathOpts(path, meta, artifact_policy_for_component(component)))
        local reply, err = artifact_cap:call_control('import_path', opts)
        if not reply then return nil, nil, err end
        if reply.ok ~= true then return nil, nil, reply.reason end
        local artefact = reply.reason
        local rec, rerr = artifact_snapshot(artefact)
        if not rec then return nil, nil, rerr end
        return artefact:ref(), rec, nil
    end


    local function save_job(job)
        local ok, err = repo:save_job(job)
        if not ok then
            svc:obs_log('error', { what = 'job_save_failed', err = tostring(err), job_id = job and job.job_id })
            return nil, err
        end
        return true, nil
    end

    local function update_job(job, patch, opts_)
        opts_ = opts_ or {}
        local state_changed = false
        for k, v in pairs(patch) do
            if job[k] ~= v then
                if k == 'state' then state_changed = true end
                job[k] = v
            end
        end
        if opts_.runtime_merge then
            job.runtime = type(job.runtime) == 'table' and job.runtime or {}
            for k, v in pairs(opts_.runtime_merge) do job.runtime[k] = v end
        end
        if state_changed then
            job.runtime = type(job.runtime) == 'table' and job.runtime or {}
            job.runtime.phase_run_id = service_run_id
            job.runtime.phase_mono = svc:now()
        end
        job.updated_seq = next_seq()
        job.updated_mono = svc:now()
        local ok, err = save_job(job)
        if ok then mark_job_dirty(job.job_id) end
        if not opts_.no_signal then changed:signal() end
        return ok, err
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
        job.artifact_released_at = svc:now()
        job.updated_seq = next_seq()
        job.updated_mono = svc:now()
        save_job(job)
        mark_job_dirty(job.job_id)
        changed:signal()
    end

    local function rebuild_backends()
        backends = {}
        for component, ccfg in pairs(cfg.components) do
            local backend, berr = build_backend(component, ccfg)
            if backend then
                backends[component] = backend
            else
                svc:obs_log('warn', { what = 'backend_build_failed', component = component, err = tostring(berr) })
            end
        end
    end

    local function adopt_repo(new_repo)
        local loaded, err = new_repo:load_all()
        if not loaded then
            svc:obs_log('warn', { what = 'repo_reload_failed', err = tostring(err) })
            return nil, err
        end
        repo = new_repo
        store = loaded
        sort_store(store)
        for _, id in ipairs(store.order) do
            local job = store.jobs[id]
            if job then
                job.runtime = type(job.runtime) == 'table' and job.runtime or {}
            end
        end
        seed_seq_from_store()
        mark_all_jobs_dirty()
        return true, nil
    end

    local function adopt_persisted_jobs()
        for _, id in ipairs(store.order) do
            local job = store.jobs[id]
            if job then
                job.runtime = type(job.runtime) == 'table' and job.runtime or {}
                if job.state == 'staging' then
                    if type(job.artifact_ref) == 'string' and job.artifact_ref ~= '' then
                        update_job(job, {
                            state = 'created',
                            next_step = nil,
                            error = job.error,
                        }, { runtime_merge = { adopted = true } })
                    else
                        update_job(job, {
                            state = 'failed',
                            next_step = nil,
                            error = 'interrupted_before_stage',
                        }, { runtime_merge = { adopted = true } })
                    end
                elseif job.state == 'awaiting_return' then
                    update_job(job, {
                        state = 'awaiting_return',
                        next_step = 'reconcile',
                    }, { runtime_merge = { adopted = true } })
                elseif job.state == 'awaiting_approval' or job.state == 'deferred' or job.state == 'staged' then
                    update_job(job, {
                        state = 'awaiting_commit',
                        next_step = 'commit',
                    }, { runtime_merge = { adopted = true } })
                end
            end
        end
    end

    local function build_job_artifact(payload)
        local component = assert(payload.component, 'component required')
        if not cfg.components[component] then return nil, nil, 'unknown_component' end

        local artifact_ref = payload.artifact_ref
        local artifact_meta = nil
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
        if type(artifact_ref) ~= 'string' or artifact_ref == '' then return nil, nil, 'artifact_required' end
        return artifact_ref, artifact_meta, nil
    end

    local function create_job(payload)
        local component = assert(payload.component, 'component required')
        if not cfg.components[component] then return nil, 'unknown_component' end
        local artifact_ref, artifact_meta, aerr = build_job_artifact(payload)
        if not artifact_ref then return nil, aerr end

        local created_seq = next_seq()
        local now_mono = svc:now()
        local job_id = tostring(uuid.new())
        local job = {
            job_id = job_id,
            offer_id = payload.offer_id,
            component = component,
            artifact_ref = artifact_ref,
            artifact_meta = artifact_meta,
            expected_version = payload.expected_version,
            metadata = type(payload.metadata) == 'table' and payload.metadata or nil,
            state = 'created',
            next_step = nil,
            created_seq = created_seq,
            updated_seq = created_seq,
            created_mono = now_mono,
            updated_mono = now_mono,
            result = nil,
            error = nil,
            runtime = {
                attempt = 0,
                adopted = false,
                active_lock = nil,
                last_progress = nil,
                phase_run_id = service_run_id,
                phase_mono = now_mono,
            },
        }
        store.jobs[job_id] = job
        store.order[#store.order + 1] = job_id
        sort_store(store)
        save_job(job)
        mark_job_dirty(job_id)
        changed:signal()
        return job, nil
    end

    local function clone_job_for_retry(src)
        local job, err = create_job({
            component = src.component,
            offer_id = src.offer_id,
            artifact_ref = src.artifact_ref,
            expected_version = src.expected_version,
            metadata = copy_value(src.metadata),
        })
        if not job then return nil, err end
        update_job(src, { state = 'superseded', next_step = nil, error = nil })
        return job, nil
    end

    local function has_active_global()
        return locks.global ~= nil
    end

    local function can_activate(job)
        if active_job and active_job.job_id == job.job_id then return nil, 'job_already_active' end
        if has_active_global() then return nil, 'busy_global' end
        return true, nil
    end

    local function release_lock(job_id)
        local job = store.jobs[job_id]
        if job and type(job.runtime) == 'table' then
            job.runtime.active_lock = nil
            job.updated_seq = next_seq()
            job.updated_mono = svc:now()
            save_job(job)
            mark_job_dirty(job.job_id)
        end
        if locks.global == job_id then locks.global = nil end
        for component, holder in pairs(locks.component) do
            if holder == job_id then locks.component[component] = nil end
        end
        summary_dirty = true
    end

    local function acquire_lock(job)
        locks.global = job.job_id
        locks.component[job.component] = job.job_id
        job.runtime = type(job.runtime) == 'table' and job.runtime or {}
        job.runtime.active_lock = 'global:' .. tostring(job.job_id)
        job.updated_seq = next_seq()
        job.updated_mono = svc:now()
        save_job(job)
        mark_job_dirty(job.job_id)
    end

    local function demote_to_passive(job, state, next_step, extra_patch)
        release_lock(job.job_id)
        local patch = {
            state = state,
            next_step = next_step,
        }
        if type(extra_patch) == 'table' then
            for k, v in pairs(extra_patch) do patch[k] = v end
        end
        return update_job(job, patch)
    end

    local function start_worker(job)
        if active_job and active_job.job_id == job.job_id then return true, nil end
        local child, err = service_scope:child()
        if not child then return nil, err end
        acquire_lock(job)
        local ok, spawn_err = child:spawn(function()
            local backend = backends[job.component]
            if not backend then
                update_job(job, { state = 'failed', error = 'backend_missing', next_step = nil })
                release_artifact_if_present(job)
                return
            end

            local function fail_job(reason, state)
                update_job(job, { state = state or 'failed', error = tostring(reason), next_step = nil })
                return nil, reason
            end

            local function run_reconcile_loop()
                local deadline = svc:now() + cfg.reconcile.timeout_s
                while true do
                    local result, rerr = backend:reconcile(conn, job)
                    if result ~= nil then
                        if result.done and result.success then
                            update_job(job, {
                                state = 'succeeded',
                                result = result,
                                error = nil,
                                next_step = nil,
                                post_commit_incarnation = result.incarnation,
                            })
                            release_artifact_if_present(job)
                            return true, nil
                        elseif result.done then
                            update_job(job, {
                                state = 'failed',
                                result = result,
                                error = tostring(result.error or rerr or 'failed'),
                                next_step = nil,
                            })
                            return nil, rerr or result.error
                        else
                            update_job(job, {
                                state = 'awaiting_return',
                                result = result,
                                error = nil,
                                next_step = 'reconcile',
                            }, { runtime_merge = {
                                awaiting_return_run_id = service_run_id,
                                awaiting_return_mono = svc:now(),
                            } })
                        end
                    end
                    if svc:now() >= deadline then
                        update_job(job, {
                            state = 'timed_out',
                            result = nil,
                            error = tostring(rerr or 'timeout'),
                            next_step = nil,
                        })
                        return nil, 'timeout'
                    end
                    sleep.sleep(cfg.reconcile.interval_s)
                end
            end

            job.runtime = type(job.runtime) == 'table' and job.runtime or {}
            job.runtime.attempt = (job.runtime.attempt or 0) + 1

            if job.next_step == 'reconcile' then
                update_job(job, { state = 'awaiting_return', next_step = 'reconcile' }, { runtime_merge = {
                    adopted = false,
                    awaiting_return_run_id = service_run_id,
                    awaiting_return_mono = svc:now(),
                } })
                return run_reconcile_loop()
            end

            if job.next_step ~= 'commit' then
                update_job(job, { state = 'staging', next_step = 'stage', error = nil })
                local status_before = backend:status(conn)
                if status_before and status_before.state and type(status_before.state) == 'table' then
                    job.pre_commit_incarnation = status_before.state.incarnation or status_before.state.generation
                    job.updated_seq = next_seq()
                    job.updated_mono = svc:now()
                    save_job(job)
                    mark_job_dirty(job.job_id)
                end
                local prep, perr = backend:prepare(conn, job)
                if prep == nil then return fail_job(perr) end

                local staged, serr = backend:stage(conn, job)
                if staged == nil then return fail_job(serr) end

                if type(staged) == 'table' and staged.artifact_retention == 'release' then
                    release_artifact_if_present(job)
                end
                demote_to_passive(job, 'awaiting_commit', 'commit', {
                    result = staged,
                    staged_meta = staged,
                    error = nil,
                })
                return true, nil
            end

            local committed, cerr = backend:commit(conn, job)
            if committed == nil then return fail_job(cerr) end
            update_job(job, { state = 'awaiting_return', result = committed, error = nil, next_step = 'reconcile' }, { runtime_merge = {
                awaiting_return_run_id = service_run_id,
                awaiting_return_mono = svc:now(),
            } })
            return run_reconcile_loop()
        end)
        if not ok then
            release_lock(job.job_id)
            return nil, spawn_err
        end
        active_job = { job_id = job.job_id, scope = child, component = job.component, started_at = svc:now() }
        summary_dirty = true
        changed:signal()
        return true, nil
    end

    local function list_jobs_payload()
        return public_jobs(store)
    end

    local function select_resumable_job()
        if active_job or has_active_global() then return nil end
        for _, id in ipairs(store.order) do
            local job = store.jobs[id]
            if job and job.state == 'awaiting_return' and job.next_step == 'reconcile' then
                return job
            end
        end
        return nil
    end

    local create_ep = conn:bind({ 'cmd', 'update', 'job', 'create' }, { queue_len = 32 })
    local do_ep = conn:bind({ 'cmd', 'update', 'job', 'do' }, { queue_len = 32 })
    local get_ep = conn:bind({ 'cmd', 'update', 'job', 'get' }, { queue_len = 32 })
    local list_ep = conn:bind({ 'cmd', 'update', 'job', 'list' }, { queue_len = 32 })

    rebuild_backends()
    adopt_repo(repo)
    adopt_persisted_jobs()
    flush_publications()
    changed:signal()
    svc:status('running')

    local seen = changed:version()
    while true do
        local ops = {
            cfg = cfg_watch:recv_op():wrap(function(ev) return ev end),
            create = create_ep:recv_op(),
            job_do = do_ep:recv_op(),
            get = get_ep:recv_op(),
            list = list_ep:recv_op(),
            changed = changed:changed_op(seen):wrap(function(ver) seen = ver; return ver end),
        }
        local joining = active_job
        if joining then
            ops.active_join = joining.scope:join_op():wrap(function(st, _report, primary)
                return { job_id = joining.job_id, st = st, primary = primary }
            end)
        end
        local which, req, err = fibers.perform(fibers.named_choice(ops))

        if which == 'changed' then
            flush_publications()
            local job = select_resumable_job()
            if job then
                local ok, serr = start_worker(job)
                if not ok then
                    svc:obs_log('warn', { what = 'adopted_job_resume_failed', job_id = job.job_id, err = tostring(serr) })
                end
            end
        elseif which == 'active_join' then
            local ev = req
            local current = ev and store.jobs[ev.job_id] or nil
            active_job = nil
            if ev then release_lock(ev.job_id) end
            if current and not is_terminal(current.state) and not PASSIVE_STATES[current.state] then
                if ev.st == 'failed' then
                    update_job(current, { state = 'failed', error = tostring(ev.primary or 'worker_failed'), next_step = nil })
                elseif ev.st == 'cancelled' then
                    update_job(current, { state = 'cancelled', error = tostring(ev.primary or 'worker_cancelled'), next_step = nil })
                end
            end
            flush_publications()
            local job = select_resumable_job()
            if job then
                local ok, serr = start_worker(job)
                if not ok then
                    svc:obs_log('warn', { what = 'adopted_job_resume_failed', job_id = job.job_id, err = tostring(serr) })
                end
            end
        elseif which == 'cfg' then
            local ev = req
            if not ev then
                svc:status('failed', { reason = tostring(err or 'cfg_watch_closed') })
                error('update cfg watch closed: ' .. tostring(err), 0)
            end

            local old_ns = cfg.jobs_namespace

            if ev.op == 'retain' then
                cfg = merge_cfg(ev.payload)
            elseif ev.op == 'unretain' then
                cfg = default_cfg()
            end

            rebuild_backends()

            local new_ns = cfg.jobs_namespace
            if new_ns ~= old_ns then
                if active_job or has_active_global() then
                    svc:obs_log('warn', {
                        what = 'jobs_namespace_change_ignored_while_active',
                        old = tostring(old_ns),
                        new = tostring(new_ns),
                    })
                    cfg.jobs_namespace = old_ns
                else
                    local new_repo = job_store.open(store_cap, { namespace = new_ns })
                    local ok, aerr = adopt_repo(new_repo)
                    if ok then
                        adopt_persisted_jobs()
                    else
                        svc:obs_log('warn', { what = 'repo_adopt_failed', err = tostring(aerr) })
                    end
                end
            end

            changed:signal()
        elseif which == 'create' then
            if not req then error('update create endpoint closed: ' .. tostring(err), 0) end
            local job, jerr = create_job(req.payload or {})
            if not job then
                req:fail(jerr)
            else
                req:reply({ ok = true, job = public_job(job) })
            end
        elseif which == 'job_do' then
            if not req then error('update job do endpoint closed: ' .. tostring(err), 0) end
            local payload = req.payload or {}
            local op = payload.op
            local job = store.jobs[payload.job_id]
            if type(op) ~= 'string' or op == '' then
                req:fail('invalid_op')
            elseif not job then
                req:fail('unknown_job')
            elseif op == 'start' then
                if job.state ~= 'created' then
                    req:fail('job_not_startable')
                else
                    local ok, aerr = can_activate(job)
                    if not ok then
                        req:fail(aerr)
                    else
                        local wok, werr = start_worker(job)
                        if not wok then req:fail(tostring(werr)) else req:reply({ ok = true, job = public_job(job) }) end
                    end
                end
            elseif op == 'commit' then
                if job.state ~= 'awaiting_commit' then
                    req:fail('job_not_committable')
                else
                    local ok, aerr = can_activate(job)
                    if not ok then
                        req:fail(aerr)
                    else
                        local wok, werr = start_worker(job)
                        if not wok then req:fail(tostring(werr)) else req:reply({ ok = true, job = public_job(job) }) end
                    end
                end
            elseif op == 'cancel' then
                if ACTIVE_STATES[job.state] then
                    req:fail('job_active')
                elseif TERMINAL_STATES[job.state] then
                    req:fail('job_terminal')
                elseif job.state ~= 'created' and job.state ~= 'awaiting_commit' then
                    req:fail('job_not_cancellable')
                else
                    update_job(job, { state = 'cancelled', next_step = nil, error = nil })
                    req:reply({ ok = true, job = public_job(job) })
                end
            elseif op == 'retry' then
                if not job_actions(job).retry then
                    req:fail('job_not_retryable')
                else
                    local new_job, rerr = clone_job_for_retry(job)
                    if not new_job then req:fail(rerr) else req:reply({ ok = true, job = public_job(new_job) }) end
                end
            elseif op == 'discard' then
                if not is_terminal(job.state) then
                    req:fail('job_not_discardable')
                else
                    if type(job.artifact_ref) == 'string' and job.artifact_ref ~= '' then
                        release_artifact_if_present(job)
                    end
                    local _ = repo:delete_job(job.job_id)
                    store.jobs[job.job_id] = nil
                    for i = #store.order, 1, -1 do
                        if store.order[i] == job.job_id then table.remove(store.order, i) break end
                    end
                    safe.pcall(function() conn:unretain(job_topic(job.job_id)) end)
                    summary_dirty = true
                    changed:signal()
                    req:reply({ ok = true })
                end
            else
                req:fail('invalid_op')
            end
        elseif which == 'get' then
            if not req then error('update get endpoint closed: ' .. tostring(err), 0) end
            local payload = req.payload or {}
            local job = store.jobs[payload.job_id]
            if not job then req:fail('unknown_job') else req:reply({ ok = true, job = public_job(job) }) end
        elseif which == 'list' then
            if not req then error('update list endpoint closed: ' .. tostring(err), 0) end
            req:reply({ ok = true, jobs = list_jobs_payload() })
        end
    end
end

return M
