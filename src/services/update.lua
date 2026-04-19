
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
        store_key = 'update-jobs.json',
        reconcile_interval_s = 10.0,
        reconcile_timeout_s = 180.0,
        targets = {
            cm5 = { backend = 'cm5_swupdate', component = 'cm5' },
            mcu = { backend = 'mcu_component', component = 'mcu' },
        },
    }
end

local function merge_cfg(payload)
    local cfg = default_cfg()
    local data = payload and (payload.data or payload) or nil
    if type(data) ~= 'table' then return cfg end
    if data.schema ~= nil and data.schema ~= SCHEMA then return cfg end
    if type(data.store_key) == 'string' and data.store_key ~= '' then cfg.store_key = data.store_key end
    if type(data.reconcile_interval_s) == 'number' and data.reconcile_interval_s > 0 then cfg.reconcile_interval_s = data.reconcile_interval_s end
    if type(data.reconcile_timeout_s) == 'number' and data.reconcile_timeout_s > 0 then cfg.reconcile_timeout_s = data.reconcile_timeout_s end
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
    return cfg
end

local function copy_job(job)
    local out = {}
    for k, v in pairs(job) do out[k] = v end
    return out
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

function M.start(conn, opts)
    opts = opts or {}
    local svc = base.new(conn, { name = opts.name or 'update', env = opts.env })
    local heartbeat_s = (type(opts.heartbeat_s) == 'number') and opts.heartbeat_s or 30.0
    svc:spawn_heartbeat(heartbeat_s, 'tick')
    svc:status('starting')

    local fs_listener = cap_sdk.new_cap_listener(conn, 'fs', 'state')
    local fs_cap, ferr = fs_listener:wait_for_cap({ timeout = 30.0 })
    if ferr ~= '' or not fs_cap then
        svc:status('failed', { reason = tostring(ferr or 'fs state capability not found') })
        error('update: failed to discover fs/state capability: ' .. tostring(ferr), 0)
    end

    local cfg_watch = conn:watch_retained({ 'cfg', 'update' }, { replay = true, queue_len = 8, full = 'drop_oldest' })
    local cfg = default_cfg()
    local backends = {}

    local store, serr = job_store.load(fs_cap, cfg.store_key)
    if not store then
        svc:status('failed', { reason = tostring(serr) })
        error('update: failed to load job store: ' .. tostring(serr), 0)
    end

    local changed = pulse.scoped({ close_reason = 'update service stopping' })

    local function save_store()
        local ok, err = job_store.save(fs_cap, cfg.store_key, store)
        if not ok then
            svc:obs_log('error', { what = 'job_store_save_failed', err = tostring(err) })
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
        retain_best_effort(conn, summary_topic(), {
            kind = 'update.summary',
            ts = svc:now(),
            count = #store.order,
            states = counts,
        })
    end

    local function update_job(job, patch)
        for k, v in pairs(patch) do job[k] = v end
        job.updated_at = os.time()
        publish_job(job)
        publish_summary()
        save_store()
        changed:signal()
    end

    local function rebuild_backends()
        backends = {}
        for target, tcfg in pairs(cfg.targets) do
            local backend, err = build_backend(tcfg)
            if backend then
                backends[target] = backend
            else
                svc:obs_log('error', { what = 'backend_build_failed', target = target, err = tostring(err) })
            end
        end
    end

    local function create_job(payload)
        local target = payload and payload.target
        if type(target) ~= 'string' or cfg.targets[target] == nil then
            return nil, 'invalid_target'
        end
        local job_id = tostring(uuid.new())
        local job = {
            job_id = job_id,
            offer_id = payload.offer_id,
            target = target,
            artifact = payload.artifact,
            expected_version = payload.expected_version,
            metadata = type(payload.metadata) == 'table' and payload.metadata or nil,
            approval = payload.approval or 'manual',
            state = 'available',
            created_at = os.time(),
            updated_at = os.time(),
            result = nil,
            error = nil,
        }
        store.jobs[job_id] = job
        store.order[#store.order + 1] = job_id
        publish_job(job)
        publish_summary()
        save_store()
        changed:signal()
        return job, nil
    end

    local function apply_job(job)
        local backend = backends[job.target]
        if not backend then
            update_job(job, { state = 'failed', error = 'backend_missing' })
            return nil, 'backend_missing'
        end

        update_job(job, { state = 'preparing', error = nil })
        local status_before = backend:status(conn)
        if status_before and status_before.state and type(status_before.state) == 'table' then
            job.pre_commit_incarnation = status_before.state.incarnation or status_before.state.generation
        end
        local prep, perr = backend:prepare(conn, job)
        if prep == nil then
            update_job(job, { state = 'failed', error = tostring(perr) })
            return nil, perr
        end

        update_job(job, { state = 'staging' })
        local staged, serr = backend:stage(conn, job)
        if staged == nil then
            update_job(job, { state = 'failed', error = tostring(serr) })
            return nil, serr
        end

        update_job(job, { state = 'staged', result = staged })
        if job.approval ~= 'manual' then
            update_job(job, { state = 'committing' })
            local committed, cerr = backend:commit(conn, job)
            if committed == nil then
                update_job(job, { state = 'failed', error = tostring(cerr) })
                return nil, cerr
            end
            update_job(job, { state = 'awaiting_return', result = committed, error = nil })
        else
            update_job(job, { state = 'awaiting_approval' })
        end
        return true, nil
    end

    local function approve_job(job)
        if job.state ~= 'awaiting_approval' and job.state ~= 'staged' then
            return nil, 'job_not_awaiting_approval'
        end
        local backend = backends[job.target]
        if not backend then
            update_job(job, { state = 'failed', error = 'backend_missing' })
            return nil, 'backend_missing'
        end
        update_job(job, { state = 'committing' })
        local committed, err = backend:commit(conn, job)
        if committed == nil then
            update_job(job, { state = 'failed', error = tostring(err) })
            return nil, err
        end
        update_job(job, { state = 'awaiting_return', result = committed, error = nil })
        return true, nil
    end

    local function reconcile_job(job)
        if job.state ~= 'awaiting_return' and job.state ~= 'verifying_postboot' and job.state ~= 'committing' then return end
        local backend = backends[job.target]
        if not backend then return end
        if job.state == 'committing' then
            update_job(job, { state = 'awaiting_return' })
        end
        local result, err = backend:reconcile(conn, job)
        if result == nil then
            if (os.time() - (job.updated_at or job.created_at or os.time())) > cfg.reconcile_timeout_s then
                update_job(job, { state = 'timed_out', result = nil, error = tostring(err or 'timeout') })
            end
            return
        end
        if result.done and result.success then
            update_job(job, { state = 'succeeded', result = result, error = nil, post_commit_incarnation = result.incarnation })
        elseif result.done then
            update_job(job, { state = 'failed', result = result, error = tostring(result.error or err or 'failed') })
        else
            -- Keep the job in awaiting_return until there is decisive post-boot
            -- evidence of success or failure. This avoids a racy transient state
            -- where fast reconcile ticks can skip over awaiting_return entirely.
            update_job(job, { state = 'awaiting_return', result = result })
        end
    end

    local function reconcile_all()
        for _, id in ipairs(store.order) do
            local job = store.jobs[id]
            if job then reconcile_job(job) end
        end
    end

    local create_ep = conn:bind({ 'cmd', 'update', 'job', 'create' }, { queue_len = 32 })
    local apply_ep = conn:bind({ 'cmd', 'update', 'job', 'apply_now' }, { queue_len = 32 })
    local approve_ep = conn:bind({ 'cmd', 'update', 'job', 'approve' }, { queue_len = 32 })
    local defer_ep = conn:bind({ 'cmd', 'update', 'job', 'defer' }, { queue_len = 32 })
    local get_ep = conn:bind({ 'cmd', 'update', 'job', 'get' }, { queue_len = 32 })
    local list_ep = conn:bind({ 'cmd', 'update', 'job', 'list' }, { queue_len = 32 })

    rebuild_backends()
    for _, id in ipairs(store.order) do
        local job = store.jobs[id]
        if job then publish_job(job) end
    end
    publish_summary()
    reconcile_all()
    svc:status('running')

    fibers.spawn(function()
        local seen = changed:version()
        while true do
            local which = fibers.perform(fibers.named_choice({
                tick = sleep.sleep_op(cfg.reconcile_interval_s):wrap(function() return 'tick' end),
                changed = changed:changed_op(seen):wrap(function(ver)
                    seen = ver
                    return 'changed'
                end),
            }))
            if which then
                reconcile_all()
            end
        end
    end)

    while true do
        local which, req, err = fibers.perform(fibers.named_choice({
            cfg = cfg_watch:recv_op(),
            create = create_ep:recv_op(),
            apply = apply_ep:recv_op(),
            approve = approve_ep:recv_op(),
            defer = defer_ep:recv_op(),
            get = get_ep:recv_op(),
            list = list_ep:recv_op(),
        }))

        if which == 'cfg' then
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
            rebuild_backends()
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
            else
                local ok, aerr = apply_job(job)
                if not ok then req:fail(aerr) else req:reply({ ok = true, job = copy_job(job) }) end
            end
        elseif which == 'approve' then
            if not req then error('update approve endpoint closed: ' .. tostring(err), 0) end
            local payload = req.payload or {}
            local job = store.jobs[payload.job_id]
            if not job then
                req:fail('unknown_job')
            else
                local ok, aerr = approve_job(job)
                if not ok then req:fail(aerr) else req:reply({ ok = true, job = copy_job(job) }) end
            end
        elseif which == 'defer' then
            if not req then error('update defer endpoint closed: ' .. tostring(err), 0) end
            local payload = req.payload or {}
            local job = store.jobs[payload.job_id]
            if not job then
                req:fail('unknown_job')
            elseif job.state ~= 'awaiting_approval' and job.state ~= 'available' then
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
            local jobs = {}
            for _, id in ipairs(store.order) do
                local job = store.jobs[id]
                if job then jobs[#jobs + 1] = copy_job(job) end
            end
            req:reply({ ok = true, jobs = jobs })
        end
    end
end

return M
