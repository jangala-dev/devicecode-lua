local busmod      = require 'bus'
local runfibers   = require 'tests.support.run_fibers'
local probe       = require 'tests.support.bus_probe'
local fibers      = require 'fibers'
local sleep_mod   = require 'fibers.sleep'
local safe        = require 'coxpcall'
local storagecaps = require 'tests.support.storage_caps'

local device = require 'services.device'
local update = require 'services.update'

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

local function start_cm5_updater_cap(scope, conn, state)
    conn:retain({ 'cap', 'updater', 'cm5', 'state' }, 'added')
    conn:retain({ 'cap', 'updater', 'cm5', 'meta' }, { offerings = { prepare = true, stage = true, commit = true, status = true } })

    local function publish_status()
        conn:publish({ 'cap', 'updater', 'cm5', 'state', 'status' }, {
            state = state.state,
            fw_version = state.fw_version,
            expected_version = state.expected_version,
            staged = state.staged,
            artifact_ref = state.artifact_ref,
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
            artifact_ref = state.artifact_ref,
        }
    end)

    bind_reply_loop(scope, prepare_ep, function(payload)
        return { ok = true, target = payload.target, fw_version = state.fw_version }
    end)

    bind_reply_loop(scope, stage_ep, function(payload)
        state.state = 'staged'
        state.staged = true
        state.artifact_ref = payload.artifact_ref
        state.expected_version = payload.expected_version
        publish_status()
        return { ok = true, staged = payload.artifact_ref, expected_version = payload.expected_version, artifact_retention = 'keep' }
    end)

    bind_reply_loop(scope, commit_ep, function(payload)
        state.state = 'committing'
        publish_status()
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

local function wait_service_running(conn, topic)
    return wait_retained_state(conn, topic, function(payload)
        return type(payload) == 'table' and payload.state == 'running'
    end, 0.75)
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

function T.devhost_getbox_style_cm5_update_reconciles_after_restart_with_transient_artifact_loss()
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
        local control = storagecaps.start_control_store_cap(scope, bus:connect(), {})
        local artifacts = storagecaps.start_artifact_store_cap(scope, bus:connect(), { durable_enabled = false })
        local seed = bus:connect()
        seed:retain({ 'cfg', 'update' }, {
            schema = 'devicecode.config/update/1',
            artifact_policy_default = 'transient_only',
            artifact_policies = { cm5 = 'transient_only' },
        })

        local updater_state = {
            state = 'idle',
            fw_version = 'cm5-v0',
            expected_version = nil,
            staged = false,
            artifact_ref = nil,
        }
        local publish_status = start_cm5_updater_cap(scope, bus:connect(), updater_state)

        local ok1, err1 = scope:spawn(function()
            device.start(bus:connect(), { name = 'device', env = 'dev' })
        end)
        assert(ok1, tostring(err1))

        local update_scope = start_update_service(scope, bus)

        assert(wait_service_running(caller, { 'svc', 'update', 'status' }))

        local created, cerr = caller:call({ 'cmd', 'update', 'job', 'create' }, {
            target = 'cm5',
            artifact_data = 'getbox-firmware-image-v2',
            expected_version = 'cm5-v2',
            metadata = { next_version = 'cm5-v2' },
            approval = 'manual',
        }, { timeout = 0.5 })
        assert(cerr == nil)
        assert(created.ok == true)
        local job = created.job
        local artifact_ref = job.artifact_ref
        assert(type(artifact_ref) == 'string')
        assert(type(job.artifact_meta) == 'table')
        assert(job.artifact_meta.durability == 'transient')
        assert(type(artifacts.artifacts[artifact_ref]) == 'table')
        assert(artifacts.artifacts[artifact_ref].durability == 'transient')

        local applied, aerr = caller:call({ 'cmd', 'update', 'job', 'apply_now' }, { job_id = job.job_id }, { timeout = 1.0 })
        assert(aerr == nil)
        assert(applied.ok == true)
        assert(applied.job.state == 'awaiting_approval')

        local approved, perr = caller:call({ 'cmd', 'update', 'job', 'approve' }, { job_id = job.job_id }, { timeout = 1.0 })
        assert(perr == nil)
        assert(approved.ok == true)
        assert(type(approved.job.artifact_ref) == 'string')

        local awaiting = wait_retained_state(caller, { 'state', 'update', 'jobs', job.job_id }, function(payload)
            return type(payload) == 'table' and type(payload.job) == 'table' and payload.job.state == 'awaiting_return'
        end, 0.75)
        assert(awaiting)

        local mid, mid_err = caller:call({ 'cmd', 'update', 'job', 'get' }, { job_id = job.job_id }, { timeout = 0.5 })
        assert(mid_err == nil)
        assert(mid.ok == true)
        assert(mid.job.state == 'awaiting_return')
        assert(mid.job.artifact_ref == artifact_ref)
        assert(mid.job.artifact_released_at == nil)
        assert(type(artifacts.artifacts[artifact_ref]) == 'table')

        update_scope:cancel('restart update service')
        local outer_st, child_st = fibers.current_scope():try(update_scope:join_op())
        assert(outer_st == 'ok')
        assert(child_st == 'cancelled')

        -- Simulate reboot semantics for a Get Box-style transient artifact spool:
        -- durable control records survive, but transient artifact bytes do not.
        artifacts.artifacts = {}
        artifacts.next_id = artifacts.next_id or 0

        updater_state.state = 'running'
        updater_state.staged = false
        updater_state.artifact_ref = nil
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
                and payload.job.artifact_ref == nil
                and type(payload.job.artifact_released_at) == 'number'
        end, 1.5))

        local final, ferr = caller:call({ 'cmd', 'update', 'job', 'get' }, { job_id = job.job_id }, { timeout = 0.5 })
        assert(ferr == nil)
        assert(final.ok == true)
        assert(final.job.state == 'succeeded')
        assert(final.job.artifact_ref == nil)
        assert(type(final.job.artifact_released_at) == 'number')
        assert(next(artifacts.artifacts) == nil)

        local persisted = control.namespaces['update/jobs'][job.job_id]
        assert(type(persisted) == 'table')
        assert(persisted.state == 'succeeded')
        assert(persisted.artifact_ref == nil)
        assert(type(persisted.artifact_released_at) == 'number')
    end, { timeout = 4.0 })
end

return T
