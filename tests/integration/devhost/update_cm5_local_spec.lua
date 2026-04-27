local busmod     = require 'bus'
local runfibers  = require 'tests.support.run_fibers'
local test_diag = require 'tests.support.test_diag'
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
    conn:retain({ 'raw', 'host', 'updater', 'cap', 'updater', 'cm5', 'status' }, 'added')
    conn:retain({ 'raw', 'host', 'updater', 'cap', 'updater', 'cm5', 'meta' }, { offerings = { prepare = true, stage = true, commit = true } })

    local function publish_status()
        conn:retain({ 'raw', 'host', 'updater', 'cap', 'updater', 'cm5', 'state', 'software' }, {
            version = state.fw_version,
            boot_id = state.boot_id,
            image_id = state.expected_image_id or state.fw_version,
        })
        conn:retain({ 'raw', 'host', 'updater', 'cap', 'updater', 'cm5', 'state', 'updater' }, {
            state = state.state,
            staged = state.staged,
            artifact_ref = state.artifact_ref,
            expected_image_id = state.expected_image_id,
            last_error = state.last_error,
        })
        conn:retain({ 'raw', 'host', 'updater', 'cap', 'updater', 'cm5', 'state', 'health' }, {
            state = state.health or 'ok',
            reason = state.health_reason,
        })
    end

    local prepare_ep = conn:bind({ 'raw', 'host', 'updater', 'cap', 'updater', 'cm5', 'rpc', 'prepare' }, { queue_len = 16 })
    local stage_ep = conn:bind({ 'raw', 'host', 'updater', 'cap', 'updater', 'cm5', 'rpc', 'stage' }, { queue_len = 16 })
    local commit_ep = conn:bind({ 'raw', 'host', 'updater', 'cap', 'updater', 'cm5', 'rpc', 'commit' }, { queue_len = 16 })

    bind_reply_loop(scope, prepare_ep, function(payload)
        return { ok = true, prepared = true, fw_version = state.fw_version }
    end)

    bind_reply_loop(scope, stage_ep, function(payload)
        state.state = 'staged'
        state.staged = true
        state.artifact_ref = payload.artifact_ref
        state.expected_image_id = payload.expected_image_id
        publish_status()
        return { ok = true, staged = payload.artifact_ref, expected_image_id = payload.expected_image_id, artifact_retention = 'keep' }
    end)

    bind_reply_loop(scope, commit_ep, function(payload)
        state.state = 'committing'
        publish_status()
        local next_image_id = (payload.metadata and payload.metadata.next_image_id) or state.expected_image_id or 'cm5-v1'
        local ok, err = scope:spawn(function()
            sleep_mod.sleep(0.03)
            state.state = 'running'
            state.staged = false
            state.artifact_ref = nil
            state.fw_version = next_image_id
            state.boot_id = tostring((state.boot_id or 'cm5-boot') .. '-next')
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
        local diag = test_diag.for_stack(scope, bus, { update = true, device = true, max_records = 320 })
        test_diag.add_subsystem(diag, 'update', {
            service_fn = test_diag.retained_fn(caller, { 'svc', 'update', 'status' }),
            store_fn = function() return control.namespaces['update/jobs'] or {} end,
            artifacts_fn = function() return artifacts.artifacts end,
        })
        test_diag.add_subsystem(diag, 'device', {
            summary_fn = test_diag.retained_fn(caller, { 'state', 'device' }),
            cm5_fn = test_diag.retained_fn(caller, { 'state', 'device', 'component', 'cm5' }),
        })
        local publish_status = start_cm5_updater_cap(scope, bus:connect(), {
            state = 'idle',
            fw_version = 'cm5-v0',
            expected_image_id = nil,
            staged = false,
            artifact_ref = nil,
            boot_id = 'cm5-boot-1',
        })

        local ok1, err1 = scope:spawn(function()
            device.start(bus:connect(), { name = 'device', env = 'dev' })
        end)
        assert(ok1, tostring(err1))

        local ok2, err2 = scope:spawn(function()
            update.start(bus:connect(), { name = 'update', env = 'dev' })
        end)
        assert(ok2, tostring(err2))

        probe.wait_service_running(caller, 'update', { timeout = 0.75 })

        publish_status()
        probe.wait_device_component(caller, 'cm5', function(payload)
            return payload.available == true
                and payload.ready == true
                and type(payload.software) == 'table'
                and type(payload.updater) == 'table'
        end, { timeout = 0.75 })

        local created, cerr = caller:call({ 'cap', 'update-manager', 'main', 'rpc', 'create-job' }, {
            component = 'cm5',
            artifact = { kind = 'import_path', path = storagecaps.seed_import_path(artifacts, '/tmp/cm5-firmware-image.bin', 'cm5-firmware-image') },
            expected_image_id = 'cm5-v1',
            metadata = { next_image_id = 'cm5-v1' },
        }, { timeout = 0.5 })
        assert(cerr == nil)
        assert(created.ok == true)
        local job = created.job
        assert(type(job.artifact.ref) == 'string')
        assert(type(artifacts.artifacts[job.artifact.ref]) == 'table')

        assert(job.lifecycle.state == 'created')
        assert(type(job.artifact.ref) == 'string')

        local started, serr = caller:call({ 'cap', 'update-manager', 'main', 'rpc', 'start-job' }, { job_id = job.job_id }, { timeout = 0.5 })
        assert(serr == nil)
        assert(started.ok == true)

        probe.wait_retained_state(caller, { 'state', 'workflow', 'update-job', job.job_id }, function(payload)
            return type(payload) == 'table' and type(payload.job) == 'table' and payload.job.lifecycle.state == 'awaiting_commit'
        end, { timeout = 0.75 })

        local committed, perr = caller:call({ 'cap', 'update-manager', 'main', 'rpc', 'commit-job' }, { job_id = job.job_id }, { timeout = 1.0 })
        assert(perr == nil)
        assert(committed.ok == true)

        probe.wait_update_job(caller, job.job_id, function(payload)
            return payload.job.lifecycle.state == 'succeeded'
                and type(payload.job.result) == 'table'
                and payload.job.result.image_id == 'cm5-v1'
                and payload.job.artifact.ref == nil
        end, { timeout = 1.5 })

        assert(next(artifacts.artifacts) == nil)
        assert(type(control.namespaces['update/jobs'][job.job_id]) == 'table')
    end, { timeout = 3.0 })
end

return T
