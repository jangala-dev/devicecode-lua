
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
        local next_version = (payload.metadata and payload.metadata.next_version) or state.expected_version or 'cm5-v1'
        local ok, err = scope:spawn(function()
            sleep_mod.sleep(0.03)
            state.state = 'running'
            state.staged = false
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
        local storage = {}
        start_fs_state_cap(scope, bus:connect(), storage)
        local publish_status = start_cm5_updater_cap(scope, bus:connect(), {
            state = 'idle',
            fw_version = 'cm5-v0',
            expected_version = nil,
            staged = false,
            artifact = nil,
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

        assert(probe.wait_until(function()
            local ok, payload = safe.pcall(function()
                return probe.wait_payload(caller, { 'state', 'device', 'component', 'cm5' }, { timeout = 0.02 })
            end)
            return ok and type(payload) == 'table' and type(payload.status) == 'table' and payload.status.fw_version == 'cm5-v0'
        end, { timeout = 0.75, interval = 0.01 }))

        local created, cerr = caller:call({ 'cmd', 'update', 'job', 'create' }, {
            target = 'cm5',
            artifact = '/data/artifacts/cm5.itb',
            expected_version = 'cm5-v1',
            metadata = { next_version = 'cm5-v1' },
            approval = 'manual',
        }, { timeout = 0.5 })
        assert(cerr == nil)
        assert(created.ok == true)
        local job = created.job

        local applied, aerr = caller:call({ 'cmd', 'update', 'job', 'apply_now' }, { job_id = job.job_id }, { timeout = 1.0 })
        assert(aerr == nil)
        assert(applied.ok == true)
        assert(applied.job.state == 'awaiting_approval')

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
        end, { timeout = 1.5, interval = 0.01 }))

        local comp, derr = caller:call({ 'cmd', 'device', 'component', 'status' }, { component = 'cm5' }, { timeout = 0.5 })
        assert(derr == nil)
        assert(comp.ok == true)
        assert(type(comp.state) == 'table')
        assert(comp.state.fw_version == 'cm5-v1')
    end, { timeout = 3.0 })
end

return T
