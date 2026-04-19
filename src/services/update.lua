local fibers    = require 'fibers'
local sleep     = require 'fibers.sleep'
local pulse     = require 'fibers.pulse'
local base      = require 'devicecode.service_base'
local cap_sdk   = require 'services.hal.sdk.cap'
local job_store = require 'services.update.job_store'
local cm5_backend_mod = require 'services.update.backends.cm5_swupdate'
local mcu_backend_mod = require 'services.update.backends.mcu_component'
local uuid      = require 'uuid'
local safe      = require 'coxpcall'

local M = {}
local SCHEMA = 'devicecode.config/update/1'

local ACTIVE_STATES = {
    preparing = true,
    staging = true,
    committing = true,
    awaiting_return = true,
}

local TERMINAL_STATES = {
    succeeded = true,
    failed = true,
    rolled_back = true,
    cancelled = true,
    timed_out = true,
    superseded = true,
}

local PASSIVE_STATES = {
    available = true,
    queued = true,
    staged = true,
    awaiting_approval = true,
    deferred = true,
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
        store_namespace = 'update/jobs',
        reconcile_interval_s = 10.0,
        reconcile_timeout_s = 180.0,
        artifact_policy_default = 'transient_only',
        artifact_policies = {
            cm5 = 'transient_only',
            mcu = 'transient_only',
        },
        targets = {
            cm5 = { backend = 'cm5_swupdate', component = 'cm5' },
            mcu = { backend = 'mcu_component', component = 'mcu' },
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
    if type(data.store_namespace) == 'string' and data.store_namespace ~= '' then cfg.store_namespace = data.store_namespace end
    if type(data.reconcile_interval_s) == 'number' and data.reconcile_interval_s > 0 then cfg.reconcile_interval_s = data.reconcile_interval_s end
    if type(data.reconcile_timeout_s) == 'number' and data.reconcile_timeout_s > 0 then cfg.reconcile_timeout_s = data.reconcile_timeout_s end
    if type(data.artifact_policy_default) == 'string' and data.artifact_policy_default ~= '' then cfg.artifact_policy_default = data.artifact_policy_default end
    if type(data.artifact_policies) == 'table' then
        for target, policy in pairs(data.artifact_policies) do
            if type(target) == 'string' and type(policy) == 'string' and policy ~= '' then
                cfg.artifact_policies[target] = policy
            end
        end
    end
    if type(data.targets) == 'table' then
        cfg.targets = {}
        for name, spec in pairs(data.targets) do
            if type(name) == 'string' and type(spec) == 'table' and type(spec.component) == 'string' and spec.component ~= '' then
                cfg.targets[name] = {
                    backend = type(spec.backend) == 'string' and spec.backend or (name == 'cm5' and 'cm5_swupdate' or 'mcu_component'),
                    component = spec.component,
                }
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

local function sort_store(store)
    table.sort(store.order, function(a, b)
        local ja, jb = store.jobs[a], store.jobs[b]
        local ta = (ja and ja.created_at) or 0
        local tb = (jb and jb.created_at) or 0
        if ta == tb then return tostring(a) < tostring(b) end
        return ta < tb
    end)
end

local function build_backend(target_cfg)
    if target_cfg.backend == 'cm5_swupdate' then
        return cm5_backend_mod.new({ component = target_cfg.component })
    end
    if target_cfg.backend == 'mcu_component' then
        return mcu_backend_mod.new({ component = target_cfg.component })
    end
    return nil, 'unknown_backend:' .. tostring(target_cfg.backend)
end

local function discover_cap(conn, class, id, timeout)
    local listener = cap_sdk.new_cap_listener(conn, class, id)
    local cap, err = listener:wait_for_cap({ timeout = timeout or 30.0 })
    listener:close()
    return cap, err
end

local function now_ts()
    return os.time()
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
    local repo = job_store.open(store_cap, { namespace = cfg.store_namespace })
    local store, lerr = repo:load_all()
    if not store then
        svc:status('failed', { reason = tostring(lerr) })
        error('update: failed to load job store: ' .. tostring(lerr), 0)
    end

    local changed = pulse.scoped({ close_reason = 'update service stopping' })
    local active_jobs = {}
    local locks = { global = nil, target = {} }
    local backends = {}

    local function is_terminal(state)
        return TERMINAL_STATES[state] == true
    end

    local function is_active(state)
        return ACTIVE_STATES[state] == true
    end

    local function artifact_policy_for_target(target)
        return cfg.artifact_policies[target] or cfg.artifact_policy_default or 'prefer_durable'
    end

    local function artifact_describe(ref)
        local opts = assert(cap_sdk.args.new.ArtifactStoreDescribeOpts(ref))
        local reply, err = artifact_cap:call_control('describe', opts)
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

    local function artifact_import_path(path, target, metadata)
        local meta = { kind = 'update', target = target, metadata = metadata }
        local opts = assert(cap_sdk.args.new.ArtifactStoreImportPathOpts(path, meta, artifact_policy_for_target(target)))
        local reply, err = artifact_cap:call_control('import_path', opts)
        if not reply then return nil, nil, err end
        if reply.ok ~= true then return nil, nil, reply.reason end
        local rec = reply.reason
        return rec.artifact_ref, rec, nil
    end

    local function artifact_from_data(data, target, metadata)
        local c_opts = assert(cap_sdk.args.new.ArtifactStoreCreateOpts({ kind = 'update', target = target, metadata = metadata }, artifact_policy_for_target(target)))
        local c_reply, c_err = artifact_cap:call_control('create', c_opts)
        if not c_reply then return nil, nil, c_err end
        if c_reply.ok ~= true then return nil, nil, c_reply.reason end
        local rec = c_reply.reason
        local a_opts = assert(cap_sdk.args.new.ArtifactStoreAppendOpts(rec.artifact_ref, data))
        local a_reply, a_err = artifact_cap:call_control('append', a_opts)
        if not a_reply then return nil, nil, a_err end
        if a_reply.ok ~= true then return nil, nil, a_reply.reason end
        local f_opts = assert(cap_sdk.args.new.ArtifactStoreFinaliseOpts(rec.artifact_ref))
        local f_reply, f_err = artifact_cap:call_control('finalise', f_opts)
        if not f_reply then return nil, nil, f_err end
        if f_reply.ok ~= true then return nil, nil, f_reply.reason end
        local out = f_reply.reason
        return out.artifact_ref, out, nil
    end

    local function save_job(job)
        local ok, err = repo:save_job(job)
        if not ok then
            svc:obs_log('error', { what = 'job_save_failed', err = tostring(err), job_id = job and job.job_id })
            return nil, err
        end
        return true, nil
    end

    local function publish_job(job)
        retain_best_effort(conn, job_topic(job.job_id), {
            kind = 'update.job',
            ts = svc:now(),
            job = copy_job(job),
        })
    end

    local function publish_summary()
        local counts = {}
        for _, id in ipairs(store.order) do
            local job = store.jobs[id]
            if job then counts[job.state] = (counts[job.state] or 0) + 1 end
        end
        local active = {}
        for id, rec in pairs(active_jobs) do
            active[#active + 1] = { job_id = id, target = rec.target, started_at = rec.started_at }
        end
        retain_best_effort(conn, summary_topic(), {
            kind = 'update.summary',
            ts = svc:now(),
            count = #store.order,
            states = counts,
            active = active,
            locks = copy_value(locks),
        })
    end

    local function update_job(job, patch, opts_) 
        opts_ = opts_ or {}
        for k, v in pairs(patch) do job[k] = v end
        job.updated_at = now_ts()
        if opts_.runtime_merge and type(job.runtime) == 'table' then
            for k, v in pairs(opts_.runtime_merge) do job.runtime[k] = v end
        end
        local ok, err = save_job(job)
        if ok then
            publish_job(job)
            publish_summary()
        end
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
        job.artifact_released_at = now_ts()
        save_job(job)
        publish_job(job)
        publish_summary()
        changed:signal()
    end

    local function rebuild_backends()
        backends = {}
        for target, tcfg in pairs(cfg.targets) do
            local backend, berr = build_backend(tcfg)
            if backend then
                backends[target] = backend
            else
                svc:obs_log('warn', { what = 'backend_build_failed', target = target, err = tostring(berr) })
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
        for _, id in ipairs(store.order) do
            local job = store.jobs[id]
            if job then publish_job(job) end
        end
        publish_summary()
        return true, nil
    end

    local function normalise_adopted_jobs()
        for _, id in ipairs(store.order) do
            local job = store.jobs[id]
            if job then
                job.runtime = type(job.runtime) == 'table' and job.runtime or {}
                if job.state == 'preparing' or job.state == 'staging' then
                    if type(job.artifact_ref) == 'string' and job.artifact_ref ~= '' then
                        update_job(job, {
                            state = 'queued',
                            next_step = 'run',
                            error = job.error,
                        }, { runtime_merge = { adopted = true } })
                    else
                        update_job(job, {
                            state = 'failed',
                            next_step = nil,
                            error = 'interrupted_before_stage',
                        }, { runtime_merge = { adopted = true } })
                    end
                elseif job.state == 'committing' or job.state == 'awaiting_return' then
                    update_job(job, {
                        state = 'queued',
                        next_step = 'reconcile',
                    }, { runtime_merge = { adopted = true } })
                end
            end
        end
    end

    local function create_job(payload)
        local target = assert(payload.target, 'target required')
        if not cfg.targets[target] then return nil, 'unknown_target' end

        local artifact_ref = payload.artifact_ref
        local artifact_meta = nil
        if type(artifact_ref) == 'string' and artifact_ref ~= '' then
            local desc, derr = artifact_describe(artifact_ref)
            if not desc then return nil, derr end
            artifact_meta = desc
        elseif type(payload.artifact) == 'string' and payload.artifact ~= '' then
            local ref, meta, ierr = artifact_import_path(payload.artifact, target, payload.metadata)
            if not ref then return nil, ierr end
            artifact_ref, artifact_meta = ref, meta
        elseif type(payload.artifact_data) == 'string' then
            local ref, meta, ierr = artifact_from_data(payload.artifact_data, target, payload.metadata)
            if not ref then return nil, ierr end
            artifact_ref, artifact_meta = ref, meta
        end

        local job_id = tostring(uuid.new())
        local job = {
            job_id = job_id,
            offer_id = payload.offer_id,
            target = target,
            artifact_ref = artifact_ref,
            artifact_meta = artifact_meta,
            expected_version = payload.expected_version,
            metadata = type(payload.metadata) == 'table' and payload.metadata or nil,
            approval = payload.approval or 'manual',
            state = 'available',
            next_step = nil,
            created_at = now_ts(),
            updated_at = now_ts(),
            result = nil,
            error = nil,
            runtime = {
                attempt = 0,
                adopted = false,
                active_lock = nil,
                last_progress = nil,
            },
        }
        store.jobs[job_id] = job
        store.order[#store.order + 1] = job_id
        sort_store(store)
        save_job(job)
        publish_job(job)
        publish_summary()
        changed:signal()
        return job, nil
    end

    local function has_active_global()
        return locks.global ~= nil
    end

    local function can_queue(job)
        if active_jobs[job.job_id] then return nil, 'job_already_active' end
        if has_active_global() then return nil, 'busy_global' end
        return true, nil
    end

    local function set_queued(job, next_step)
        local ok, err = can_queue(job)
        if not ok then return nil, err end
        update_job(job, {
            state = 'queued',
            next_step = next_step,
            error = nil,
        })
        return true, nil
    end

    local function release_lock(job_id)
        local job = store.jobs[job_id]
        if job and type(job.runtime) == 'table' then
            job.runtime.active_lock = nil
            save_job(job)
            publish_job(job)
        end
        if locks.global == job_id then locks.global = nil end
        for target, holder in pairs(locks.target) do
            if holder == job_id then locks.target[target] = nil end
        end
    end

    local function acquire_lock(job)
        locks.global = job.job_id
        locks.target[job.target] = job.job_id
        job.runtime = type(job.runtime) == 'table' and job.runtime or {}
        job.runtime.active_lock = 'global:' .. tostring(job.job_id)
        save_job(job)
        publish_job(job)
    end

    local function start_worker(job)
        if active_jobs[job.job_id] then return true, nil end
        local child, err = service_scope:child()
        if not child then return nil, err end
        acquire_lock(job)
        local ok, spawn_err = child:spawn(function()
            local backend = backends[job.target]
            if not backend then
                update_job(job, { state = 'failed', error = 'backend_missing', next_step = nil })
                release_artifact_if_present(job)
                return
            end

            local function fail_job(reason, state)
                update_job(job, { state = state or 'failed', error = tostring(reason), next_step = nil })
                release_artifact_if_present(job)
                return nil, reason
            end

            local function run_reconcile_loop()
                local deadline = now_ts() + cfg.reconcile_timeout_s
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
                            release_artifact_if_present(job)
                            return nil, rerr or result.error
                        else
                            update_job(job, {
                                state = 'awaiting_return',
                                result = result,
                                error = nil,
                                next_step = 'reconcile',
                            })
                        end
                    end
                    if now_ts() >= deadline then
                        update_job(job, {
                            state = 'timed_out',
                            result = nil,
                            error = tostring(rerr or 'timeout'),
                            next_step = nil,
                        })
                        release_artifact_if_present(job)
                        return nil, 'timeout'
                    end
                    sleep.sleep(cfg.reconcile_interval_s)
                end
            end

            job.runtime = type(job.runtime) == 'table' and job.runtime or {}
            job.runtime.attempt = (job.runtime.attempt or 0) + 1

            if job.next_step == 'reconcile' then
                update_job(job, { state = 'awaiting_return', next_step = 'reconcile' }, { runtime_merge = { adopted = false } })
                return run_reconcile_loop()
            end

            if job.next_step ~= 'commit_only' then
                update_job(job, { state = 'preparing', next_step = 'run', error = nil })
                local status_before = backend:status(conn)
                if status_before and status_before.state and type(status_before.state) == 'table' then
                    job.pre_commit_incarnation = status_before.state.incarnation or status_before.state.generation
                    save_job(job)
                    publish_job(job)
                end
                local prep, perr = backend:prepare(conn, job)
                if prep == nil then return fail_job(perr) end

                update_job(job, { state = 'staging', next_step = 'run' })
                local staged, serr = backend:stage(conn, job)
                if staged == nil then return fail_job(serr) end

                update_job(job, { state = 'staged', result = staged, staged_meta = staged })
                if type(staged) == 'table' and staged.artifact_retention == 'release' then
                    release_artifact_if_present(job)
                end

                if job.approval == 'manual' then
                    update_job(job, { state = 'awaiting_approval', next_step = 'commit_only' })
                    return true, nil
                end
            end

            update_job(job, { state = 'committing', next_step = 'reconcile' })
            local committed, cerr = backend:commit(conn, job)
            if committed == nil then return fail_job(cerr) end
            update_job(job, { state = 'awaiting_return', result = committed, error = nil, next_step = 'reconcile' })
            return run_reconcile_loop()
        end)
        if not ok then
            release_lock(job.job_id)
            return nil, spawn_err
        end
        active_jobs[job.job_id] = { scope = child, target = job.target, started_at = svc:now() }
        fibers.spawn(function()
            local _, st, _, primary = fibers.current_scope():try(child:join_op())
            active_jobs[job.job_id] = nil
            release_lock(job.job_id)
            local current = store.jobs[job.job_id]
            if current and not is_terminal(current.state) and not PASSIVE_STATES[current.state] then
                if st == 'failed' then
                    update_job(current, { state = 'failed', error = tostring(primary or 'worker_failed'), next_step = nil })
                    release_artifact_if_present(current)
                elseif st == 'cancelled' then
                    update_job(current, { state = 'cancelled', error = tostring(primary or 'worker_cancelled'), next_step = nil })
                    release_artifact_if_present(current)
                end
            end
            publish_summary()
            changed:signal()
        end)
        publish_summary()
        changed:signal()
        return true, nil
    end

    local function maybe_start_runnable_jobs()
        if has_active_global() then return end
        for _, id in ipairs(store.order) do
            local job = store.jobs[id]
            if job and job.state == 'queued' then
                local ok, err = start_worker(job)
                if not ok then
                    update_job(job, { state = 'failed', error = tostring(err), next_step = nil })
                    release_artifact_if_present(job)
                end
                return
            end
        end
    end

    local function list_jobs_payload()
        local jobs = {}
        for _, id in ipairs(store.order) do
            local job = store.jobs[id]
            if job then jobs[#jobs + 1] = copy_job(job) end
        end
        return jobs
    end

    local create_ep = conn:bind({ 'cmd', 'update', 'job', 'create' }, { queue_len = 32 })
    local apply_ep = conn:bind({ 'cmd', 'update', 'job', 'apply_now' }, { queue_len = 32 })
    local approve_ep = conn:bind({ 'cmd', 'update', 'job', 'approve' }, { queue_len = 32 })
    local defer_ep = conn:bind({ 'cmd', 'update', 'job', 'defer' }, { queue_len = 32 })
    local get_ep = conn:bind({ 'cmd', 'update', 'job', 'get' }, { queue_len = 32 })
    local list_ep = conn:bind({ 'cmd', 'update', 'job', 'list' }, { queue_len = 32 })

    rebuild_backends()
    adopt_repo(repo)
    normalise_adopted_jobs()
    for _, id in ipairs(store.order) do
        local job = store.jobs[id]
        if job then publish_job(job) end
    end
    publish_summary()
    changed:signal()
    svc:status('running')

    local seen = changed:version()
    while true do
        local which, req, err = fibers.perform(fibers.named_choice({
            cfg = cfg_watch:recv_op():wrap(function(ev) return ev end),
            create = create_ep:recv_op(),
            apply = apply_ep:recv_op(),
            approve = approve_ep:recv_op(),
            defer = defer_ep:recv_op(),
            get = get_ep:recv_op(),
            list = list_ep:recv_op(),
            changed = changed:changed_op(seen):wrap(function(ver) seen = ver; return ver end),
        }))

        if which == 'changed' then
            maybe_start_runnable_jobs()
            publish_summary()
        elseif which == 'cfg' then
            local ev = req
            if not ev then
                svc:status('failed', { reason = tostring(err or 'cfg_watch_closed') })
                error('update cfg watch closed: ' .. tostring(err), 0)
            end
            if ev.op == 'retain' then
                cfg = merge_cfg(ev.payload)
            elseif ev.op == 'unretain' then
                cfg = default_cfg()
            end
            local new_repo = job_store.open(store_cap, { namespace = cfg.store_namespace })
            rebuild_backends()
            local ok, aerr = adopt_repo(new_repo)
            if ok then normalise_adopted_jobs() else svc:obs_log('warn', { what = 'repo_adopt_failed', err = tostring(aerr) }) end
            changed:signal()
        elseif which == 'create' then
            if not req then error('update create endpoint closed: ' .. tostring(err), 0) end
            local job, jerr = create_job(req.payload or {})
            if not job then req:fail(jerr) else req:reply({ ok = true, job = copy_job(job) }) end
        elseif which == 'apply' then
            if not req then error('update apply endpoint closed: ' .. tostring(err), 0) end
            local payload = req.payload or {}
            local job = store.jobs[payload.job_id]
            if not job then
                req:fail('unknown_job')
            elseif job.state ~= 'available' and job.state ~= 'deferred' then
                req:fail('job_not_runnable')
            else
                local ok, aerr = set_queued(job, job.next_step or 'run')
                if not ok then req:fail(aerr) else req:reply({ ok = true, job = copy_job(job) }) end
            end
        elseif which == 'approve' then
            if not req then error('update approve endpoint closed: ' .. tostring(err), 0) end
            local payload = req.payload or {}
            local job = store.jobs[payload.job_id]
            if not job then
                req:fail('unknown_job')
            elseif job.state ~= 'awaiting_approval' and job.state ~= 'staged' and job.state ~= 'deferred' then
                req:fail('job_not_awaiting_approval')
            else
                local next_step
                if job.state == 'deferred' then
                    next_step = job.next_step or 'run'
                else
                    next_step = job.next_step or 'commit_only'
                end
                local ok, aerr = set_queued(job, next_step)
                if not ok then req:fail(aerr) else req:reply({ ok = true, job = copy_job(job) }) end
            end
        elseif which == 'defer' then
            if not req then error('update defer endpoint closed: ' .. tostring(err), 0) end
            local payload = req.payload or {}
            local job = store.jobs[payload.job_id]
            if not job then
                req:fail('unknown_job')
            elseif job.state ~= 'awaiting_approval' and job.state ~= 'available' and job.state ~= 'queued' and job.state ~= 'staged' then
                req:fail('job_not_deferrable')
            else
                update_job(job, { state = 'deferred' })
                req:reply({ ok = true, job = copy_job(job) })
            end
        elseif which == 'get' then
            if not req then error('update get endpoint closed: ' .. tostring(err), 0) end
            local payload = req.payload or {}
            local job = store.jobs[payload.job_id]
            if not job then req:fail('unknown_job') else req:reply({ ok = true, job = copy_job(job) }) end
        elseif which == 'list' then
            if not req then error('update list endpoint closed: ' .. tostring(err), 0) end
            req:reply({ ok = true, jobs = list_jobs_payload() })
        end
    end
end

return M
