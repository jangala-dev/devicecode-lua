local busmod     = require 'bus'
local runfibers  = require 'tests.support.run_fibers'
local probe      = require 'tests.support.bus_probe'
local fibers     = require 'fibers'
local sleep_mod  = require 'fibers.sleep'
local safe       = require 'coxpcall'
local storagecaps = require 'tests.support.storage_caps'

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
        local next_version = (payload.metadata and payload.metadata.next_version) or state.expected_version or 'cm5-v1'
        local ok, err = scope:spawn(function()
            sleep_mod.sleep(0.03)
            state.state = 'running'
            state.staged = false
            state.artifact_ref = nil
            state.fw_version = next_version
            publish_status()
        end)
        assert(ok, tostring(err))
        return { ok = true, started = true }
    end)

    publish_status()
    return publish_status
end

function T.devhost_cm5_update_flows_via_device_and_update_service()
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
        local artifacts = storagecaps.start_artifact_store_cap(scope, bus:connect(), {})
        local publish_status = start_cm5_updater_cap(scope, bus:connect(), {
            state = 'idle',
            fw_version = 'cm5-v0',
            expected_version = nil,
            staged = false,
            artifact_ref = nil,
        })

        local ok1, err1 = scope:spawn(function()
            device.start(bus:connect(), { name = 'device', env = 'dev' })
        end)
        assert(ok1, tostring(err1))

        local ok2, err2 = scope:spawn(function()
            update.start(bus:connect(), { name = 'update', env = 'dev' })
        end)
        assert(ok2, tostring(err2))

        assert(probe.wait_until(function()
            local ok, payload = safe.pcall(function()
                return probe.wait_payload(caller, { 'svc', 'update', 'status' }, { timeout = 0.02 })
            end)
            return ok and type(payload) == 'table' and payload.state == 'running'
        end, { timeout = 0.75, interval = 0.01 }))

        publish_status()

        local created, cerr = caller:call({ 'cmd', 'update', 'job', 'create' }, {
            target = 'cm5',
            artifact_data = 'cm5-firmware-image',
            expected_version = 'cm5-v1',
            metadata = { next_version = 'cm5-v1' },
            approval = 'manual',
        }, { timeout = 0.5 })
        assert(cerr == nil)
        assert(created.ok == true)
        local job = created.job
        assert(type(job.artifact_ref) == 'string')
        assert(type(artifacts.artifacts[job.artifact_ref]) == 'table')

        local applied, aerr = caller:call({ 'cmd', 'update', 'job', 'apply_now' }, { job_id = job.job_id }, { timeout = 1.0 })
        assert(aerr == nil)
        assert(applied.ok == true)
        assert(applied.job.state == 'awaiting_approval')
        assert(type(applied.job.artifact_ref) == 'string')

        local approved, perr = caller:call({ 'cmd', 'update', 'job', 'approve' }, { job_id = job.job_id }, { timeout = 1.0 })
        assert(perr == nil)
        assert(approved.ok == true)

        assert(probe.wait_until(function()
            local ok, payload = safe.pcall(function()
                return probe.wait_payload(caller, { 'state', 'update', 'jobs', job.job_id }, { timeout = 0.02 })
            end)
            return ok and type(payload) == 'table'
                and type(payload.job) == 'table'
                and payload.job.state == 'succeeded'
                and type(payload.job.result) == 'table'
                and payload.job.result.version == 'cm5-v1'
                and payload.job.artifact_ref == nil
        end, { timeout = 1.5, interval = 0.01 }))

        assert(next(artifacts.artifacts) == nil)
        assert(type(control.namespaces['update/jobs'][job.job_id]) == 'table')
    end, { timeout = 3.0 })
end

return T
