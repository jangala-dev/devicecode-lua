
local busmod     = require 'bus'
local runfibers  = require 'tests.support.run_fibers'
local probe      = require 'tests.support.bus_probe'
local fibers     = require 'fibers'
local sleep_mod  = require 'fibers.sleep'
local safe       = require 'coxpcall'

local device     = require 'services.device'
local update     = require 'services.update'

local T = {}

local function bind_reply_loop(scope, ep, handler)
    local ok, err = scope:spawn(function()
        while true do
            local req = ep:recv()
            if not req then return end
            local reply, ferr = handler(req.payload or {}, req)
            if reply == nil then req:fail(ferr or 'failed') else req:reply(reply) end
        end
    end)
    assert(ok, tostring(err))
end

local function start_fs_state_cap(scope, conn, storage)
    conn:retain({ 'cap', 'fs', 'state', 'state' }, 'added')
    conn:retain({ 'cap', 'fs', 'state', 'meta' }, { offerings = { read = true, write = true } })

    local read_ep = conn:bind({ 'cap', 'fs', 'state', 'rpc', 'read' }, { queue_len = 32 })
    local write_ep = conn:bind({ 'cap', 'fs', 'state', 'rpc', 'write' }, { queue_len = 32 })

    bind_reply_loop(scope, read_ep, function(payload)
        local data = storage[payload.filename]
        if data == nil then
            return { ok = false, reason = 'ENOENT' }
        end
        return { ok = true, reason = data }
    end)

    bind_reply_loop(scope, write_ep, function(payload)
        storage[payload.filename] = payload.data
        return { ok = true, reason = '' }
    end)
end

local function start_cm5_updater_cap(scope, conn, state)
    conn:retain({ 'cap', 'updater', 'cm5', 'state' }, 'added')
    conn:retain({ 'cap', 'updater', 'cm5', 'meta' }, { offerings = { prepare = true, stage = true, commit = true, status = true } })

    local function publish_status()
        conn:publish({ 'cap', 'updater', 'cm5', 'state', 'status' }, {
            state = state.state,
            fw_version = state.fw_version,
            expected_version = state.expected_version,
            staged = state.staged,
            artifact = state.artifact,
        })
    end

    local status_ep = conn:bind({ 'cap', 'updater', 'cm5', 'rpc', 'status' }, { queue_len = 16 })
    local prepare_ep = conn:bind({ 'cap', 'updater', 'cm5', 'rpc', 'prepare' }, { queue_len = 16 })
    local stage_ep = conn:bind({ 'cap', 'updater', 'cm5', 'rpc', 'stage' }, { queue_len = 16 })
    local commit_ep = conn:bind({ 'cap', 'updater', 'cm5', 'rpc', 'commit' }, { queue_len = 16 })

    bind_reply_loop(scope, status_ep, function()
        return {
            state = state.state,
            fw_version = state.fw_version,
            expected_version = state.expected_version,
            staged = state.staged,
            artifact = state.artifact,
        }
    end)

    bind_reply_loop(scope, prepare_ep, function(payload)
        return { ok = true, target = payload.target, fw_version = state.fw_version }
    end)

    bind_reply_loop(scope, stage_ep, function(payload)
        state.state = 'staged'
        state.staged = true
        state.artifact = payload.artifact
        state.expected_version = payload.expected_version
        publish_status()
        return { ok = true, staged = payload.artifact, expected_version = payload.expected_version }
    end)

    bind_reply_loop(scope, commit_ep, function(payload)
        state.state = 'committing'
        publish_status()
        -- Deliberately do not publish the new version until after the first update service is stopped.
        return { ok = true, started = true, next_version = (payload.metadata and payload.metadata.next_version) or state.expected_version }
    end)

    publish_status()
    return publish_status
end



local function wait_retained_state(conn, topic, pred, timeout)
    local w = conn:watch_retained(topic, { replay = true, queue_len = 8, full = 'drop_oldest' })
    local ok = probe.wait_until(function()
        local ev = w:recv()
        if not ev or ev.op ~= 'retain' then return false end
        return pred(ev.payload)
    end, { timeout = timeout or 0.75, interval = 0.01 })
    pcall(function() w:unwatch() end)
    return ok
end

local function wait_job_state(conn, job_id, state, timeout)
    return wait_retained_state(conn, { 'state', 'update', 'jobs', job_id }, function(payload)
        return type(payload) == 'table' and type(payload.job) == 'table' and payload.job.state == state
    end, timeout)
end

local function wait_service_running(conn, topic)
    local w = conn:watch_retained(topic, { replay = true, queue_len = 4, full = 'drop_oldest' })
    local ok = probe.wait_until(function()
        local ev = w:recv()
        if not ev or ev.op ~= 'retain' then return false end
        local payload = ev.payload
        return type(payload) == 'table' and payload.state == 'running'
    end, { timeout = 0.75, interval = 0.01 })
    pcall(function() w:unwatch() end)
    return ok
end

local function start_update_service(parent_scope, bus)
    local s, err = parent_scope:child()
    assert(s, tostring(err))
    local ok, spawn_err = s:spawn(function()
        update.start(bus:connect(), { name = 'update', env = 'dev' })
    end)
    assert(ok, tostring(spawn_err))
    return s
end

function T.devhost_update_service_reconciles_awaiting_return_job_after_restart()
    runfibers.run(function(scope)
        local orig_sleep = sleep_mod.sleep
        sleep_mod.sleep = function(dt)
            return orig_sleep(math.min(dt, 0.01))
        end
        fibers.current_scope():finally(function()
            sleep_mod.sleep = orig_sleep
        end)

        local bus = busmod.new()
        local caller = bus:connect()
        local storage = {}
        start_fs_state_cap(scope, bus:connect(), storage)
        local updater_state = {
            state = 'idle',
            fw_version = 'cm5-v0',
            expected_version = nil,
            staged = false,
            artifact = nil,
        }
        local publish_status = start_cm5_updater_cap(scope, bus:connect(), updater_state)

        local ok1, err1 = scope:spawn(function()
            device.start(bus:connect(), { name = 'device', env = 'dev' })
        end)
        assert(ok1, tostring(err1))

        local update_scope = start_update_service(scope, bus)

        assert(wait_service_running(caller, { 'svc', 'update', 'status' }))

        assert(wait_retained_state(caller, { 'state', 'device', 'component', 'cm5' }, function(payload)
            return type(payload) == 'table' and type(payload.status) == 'table' and payload.status.fw_version == 'cm5-v0'
        end, 0.75))

        local created = assert(caller:call({ 'cmd', 'update', 'job', 'create' }, {
            target = 'cm5',
            artifact = '/data/artifacts/cm5.itb',
            expected_version = 'cm5-v2',
            metadata = { next_version = 'cm5-v2' },
            approval = 'manual',
        }, { timeout = 0.5 }))
        local job = created.job

        local applied = assert(caller:call({ 'cmd', 'update', 'job', 'apply_now' }, { job_id = job.job_id }, { timeout = 1.0 }))
        assert(applied.job.state == 'awaiting_approval')

        local approved = assert(caller:call({ 'cmd', 'update', 'job', 'approve' }, { job_id = job.job_id }, { timeout = 1.0 }))
        assert(approved.ok == true)

        assert(wait_job_state(caller, job.job_id, 'awaiting_return', 0.75))

        update_scope:cancel('restart update service')
        local outer_st, child_st = fibers.current_scope():try(update_scope:join_op())
        assert(outer_st == 'ok')
        assert(child_st == 'cancelled')

        updater_state.state = 'running'
        updater_state.staged = false
        updater_state.fw_version = 'cm5-v2'
        publish_status()

        local update_scope2 = start_update_service(scope, bus)
        fibers.current_scope():finally(function()
            update_scope2:cancel('test shutdown')
        end)

        assert(wait_service_running(caller, { 'svc', 'update', 'status' }))

        assert(wait_retained_state(caller, { 'state', 'update', 'jobs', job.job_id }, function(payload)
            return type(payload) == 'table'
                and type(payload.job) == 'table'
                and payload.job.state == 'succeeded'
                and type(payload.job.result) == 'table'
                and payload.job.result.version == 'cm5-v2'
        end, 1.5))
    end, { timeout = 3.0 })
end

return T
