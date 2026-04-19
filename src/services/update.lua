
local fibers   = require 'fibers'
local sleep    = require 'fibers.sleep'
local base     = require 'devicecode.service_base'
local cap_sdk  = require 'services.hal.sdk.cap'
local job_store = require 'services.update.job_store'
local uuid     = require 'uuid'
local safe     = require 'coxpcall'

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
        reconcile_timeout_s = 180.0,
        targets = {
            cm5 = { component = 'cm5' },
            mcu = { component = 'mcu' },
        },
    }
end

local function merge_cfg(payload)
    local cfg = default_cfg()
    local data = payload and (payload.data or payload) or nil
    if type(data) ~= 'table' then return cfg end
    if data.schema ~= nil and data.schema ~= SCHEMA then return cfg end
    if type(data.store_key) == 'string' and data.store_key ~= '' then cfg.store_key = data.store_key end
    if type(data.reconcile_timeout_s) == 'number' and data.reconcile_timeout_s > 0 then cfg.reconcile_timeout_s = data.reconcile_timeout_s end
    if type(data.targets) == 'table' then
        cfg.targets = {}
        for name, spec in pairs(data.targets) do
            if type(name) == 'string' and type(spec) == 'table' and type(spec.component) == 'string' and spec.component ~= '' then
                cfg.targets[name] = { component = spec.component }
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

    local store, serr = job_store.load(fs_cap, cfg.store_key)
    if not store then
        svc:status('failed', { reason = tostring(serr) })
        error('update: failed to load job store: ' .. tostring(serr), 0)
    end

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
            if job then
                counts[job.state] = (counts[job.state] or 0) + 1
            end
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
    end

    local function call_device_status(component)
        return conn:call({ 'cmd', 'device', 'component', 'status' }, { component = component }, { timeout = 5.0 })
    end

    local function reconcile_job(job)
        if job.state ~= 'awaiting_return' and job.state ~= 'verifying_postboot' then return end
        local target = cfg.targets[job.target]
        if not target then return end
        local value, err = call_device_status(target.component)
        if value == nil then
            if (os.time() - (job.updated_at or job.created_at or os.time())) > cfg.reconcile_timeout_s then
                update_job(job, { state = 'timed_out', result = nil, error = tostring(err or 'timeout') })
            end
            return
        end
        local state = value.state or value
        local version = type(state) == 'table' and (state.fw_version or state.version or state.expected_version) or nil
        if job.expected_version and version == job.expected_version then
            update_job(job, { state = 'succeeded', result = { version = version }, error = nil })
        end
    end

    local function reconcile_all()
        for _, id in ipairs(store.order) do
            local job = store.jobs[id]
            if job then reconcile_job(job) end
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
        return job, nil
    end

    local function apply_job(job)
        local target = cfg.targets[job.target]
        if not target then
            update_job(job, { state = 'failed', error = 'target_config_missing' })
            return nil, 'target_config_missing'
        end

        update_job(job, { state = 'preparing', error = nil })
        local prep, perr = conn:call({ 'cmd', 'device', 'component', 'update' }, {
            component = target.component,
            op = 'prepare',
            args = { target = job.target, metadata = job.metadata },
        }, { timeout = 10.0 })
        if prep == nil then
            update_job(job, { state = 'failed', error = tostring(perr) })
            return nil, perr
        end

        update_job(job, { state = 'staging' })
        local staged, serr = conn:call({ 'cmd', 'device', 'component', 'update' }, {
            component = target.component,
            op = 'stage',
            args = {
                artifact = job.artifact,
                metadata = job.metadata,
                expected_version = job.expected_version,
            },
        }, { timeout = 30.0 })
        if staged == nil then
            update_job(job, { state = 'failed', error = tostring(serr) })
            return nil, serr
        end

        update_job(job, { state = 'committing' })
        local committed, cerr = conn:call({ 'cmd', 'device', 'component', 'update' }, {
            component = target.component,
            op = 'commit',
            args = { mode = job.target, metadata = job.metadata },
        }, { timeout = 10.0 })
        if committed == nil then
            update_job(job, { state = 'failed', error = tostring(cerr) })
            return nil, cerr
        end

        update_job(job, { state = 'awaiting_return', result = nil, error = nil })
        return true, nil
    end

    local create_ep = conn:bind({ 'cmd', 'update', 'job', 'create' }, { queue_len = 32 })
    local apply_ep = conn:bind({ 'cmd', 'update', 'job', 'apply_now' }, { queue_len = 32 })
    local get_ep = conn:bind({ 'cmd', 'update', 'job', 'get' }, { queue_len = 32 })
    local list_ep = conn:bind({ 'cmd', 'update', 'job', 'list' }, { queue_len = 32 })

    fibers.spawn(function()
        while true do
            sleep.sleep(10.0)
            reconcile_all()
        end
    end)

    for _, id in ipairs(store.order) do
        local job = store.jobs[id]
        if job then publish_job(job) end
    end
    publish_summary()
    svc:status('running')

    while true do
        local which, req, err = fibers.perform(fibers.named_choice({
            cfg = cfg_watch:recv_op(),
            create = create_ep:recv_op(),
            apply = apply_ep:recv_op(),
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
        elseif which == 'create' then
            if not req then error('update create endpoint closed: ' .. tostring(err), 0) end
            local job, jerr = create_job(req.payload or {})
            if not job then req:fail(jerr) else req:reply({ ok = true, job = job }) end
        elseif which == 'apply' then
            if not req then error('update apply endpoint closed: ' .. tostring(err), 0) end
            local payload = req.payload or {}
            local job = store.jobs[payload.job_id]
            if not job then
                req:fail('unknown_job')
            else
                local ok, aerr = apply_job(job)
                if not ok then req:fail(aerr) else req:reply({ ok = true, job = job }) end
            end
        elseif which == 'get' then
            if not req then error('update get endpoint closed: ' .. tostring(err), 0) end
            local payload = req.payload or {}
            local job = store.jobs[payload.job_id]
            if not job then req:fail('unknown_job') else req:reply({ ok = true, job = job }) end
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
