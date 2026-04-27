local busmod      = require 'bus'
local runfibers   = require 'tests.support.run_fibers'
local test_diag = require 'tests.support.test_diag'
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
        return { ok = true, started = true, next_image_id = (payload.metadata and payload.metadata.next_image_id) or state.expected_image_id }
    end)

    publish_status()
    return publish_status
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
        local seed = bus:connect()
        seed:retain({ 'cfg', 'update' }, {
            schema = 'devicecode.config/update/1',
            artifacts = {
                default_policy = 'transient_only',
                policies = { cm5 = 'transient_only' },
            },
        })

        local updater_state = {
            state = 'idle',
            fw_version = 'cm5-v0',
            expected_image_id = nil,
            staged = false,
            artifact_ref = nil,
            boot_id = 'cm5-boot-1',
        }
        local publish_status = start_cm5_updater_cap(scope, bus:connect(), updater_state)

        local ok1, err1 = scope:spawn(function()
            device.start(bus:connect(), { name = 'device', env = 'dev' })
        end)
        assert(ok1, tostring(err1))

        local update_scope = start_update_service(scope, bus)

        probe.wait_service_running(caller, { 'svc', 'update', 'status' }, { timeout = 0.75 })
        probe.wait_device_component(caller, 'cm5', function(payload)
            return payload.available == true
                and payload.ready == true
                and type(payload.software) == 'table'
                and type(payload.updater) == 'table'
        end, { timeout = 0.75 })

        local diag = test_diag.start_profile(scope, bus, 'update_stack', {
            conn = caller,
            control = control,
            artifacts = artifacts,
            max_records = 320,
            fabric = { session_fn = false, transfer_fn = false, summary_fn = false, service_fn = false },
            device = { cm5_fn = false, mcu_fn = false, service_fn = false, summary_fn = false },
        })

        local created, cerr = caller:call({ 'cap', 'update-manager', 'main', 'rpc', 'create-job' }, {
            component = 'cm5',
            artifact = { kind = 'import_path', path = storagecaps.seed_import_path(artifacts, '/tmp/getbox-firmware-image-v2.bin', 'getbox-firmware-image-v2') },
            expected_image_id = 'cm5-v2',
            metadata = { next_image_id = 'cm5-v2' },
        }, { timeout = 0.5 })
        assert(cerr == nil)
        assert(created.ok == true)
        local job = created.job
        local artifact_ref = job.artifact.ref
        assert(type(artifact_ref) == 'string')
        assert(type(job.artifact.meta) == 'table')
        assert(job.artifact.meta.durability == 'transient')
        assert(type(artifacts.artifacts[artifact_ref]) == 'table')
        assert(artifacts.artifacts[artifact_ref].durability == 'transient')

        assert(job.lifecycle.state == 'created')

        local started, serr = caller:call({ 'cap', 'update-manager', 'main', 'rpc', 'start-job' }, { job_id = job.job_id }, { timeout = 0.5 })
        assert(serr == nil)
        assert(started.ok == true)

        probe.wait_update_job(caller, job.job_id, function(payload)
            return type(payload.job) == 'table' and payload.job.lifecycle.state == 'awaiting_commit'
        end, { timeout = 0.75 })

        local committed, perr = caller:call({ 'cap', 'update-manager', 'main', 'rpc', 'commit-job' }, { job_id = job.job_id }, { timeout = 1.0 })
        assert(perr == nil)
        assert(committed.ok == true)
        
        test_diag.assert_retained_transitions(diag, caller, { 'state', 'workflow', 'update-job', job.job_id }, { 'awaiting_commit', 'awaiting_return' }, {
            label = 'job did not move from awaiting_commit to awaiting_return in order',
            timeout = 0.75,
            interval = 0.01,
            selector = function(payload)
                return type(payload) == 'table' and type(payload.job) == 'table' and payload.job.lifecycle and payload.job.lifecycle.state or nil
            end,
        })

        local mid, mid_err = caller:call({ 'cap', 'update-manager', 'main', 'rpc', 'get-job' }, { job_id = job.job_id }, { timeout = 0.5 })
        assert(mid_err == nil)
        assert(mid.ok == true)
        assert(mid.job.lifecycle.state == 'awaiting_return')
        assert(mid.job.artifact.ref == artifact_ref)
        assert(mid.job.artifact.released_at == nil)
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
        updater_state.boot_id = 'cm5-boot-2'
        publish_status()

        local update_scope2 = start_update_service(scope, bus)
        fibers.current_scope():finally(function()
            update_scope2:cancel('test shutdown')
        end)

        probe.wait_service_running(caller, { 'svc', 'update', 'status' }, { timeout = 0.75 })

        test_diag.assert_retained_transitions(diag, caller, { 'state', 'workflow', 'update-job', job.job_id }, { 'awaiting_return', 'succeeded' }, {
            label = 'job did not move from awaiting_return to succeeded in order',
            timeout = 1.5,
            interval = 0.01,
            selector = function(payload)
                return type(payload) == 'table' and type(payload.job) == 'table' and payload.job.lifecycle and payload.job.lifecycle.state or nil
            end,
        })

        probe.wait_update_job(caller, job.job_id, function(payload)
            return type(payload) == 'table'
                and type(payload.job) == 'table'
                and payload.job.lifecycle.state == 'succeeded'
                and type(payload.job.result) == 'table'
                and payload.job.result.image_id == 'cm5-v2'
                and payload.job.artifact.ref == nil
                and type(payload.job.artifact.released_at) == 'number'
        end, { timeout = 1.5 })

        local final, ferr = caller:call({ 'cap', 'update-manager', 'main', 'rpc', 'get-job' }, { job_id = job.job_id }, { timeout = 0.5 })
        assert(ferr == nil)
        assert(final.ok == true)
        assert(final.job.lifecycle.state == 'succeeded')
        assert(final.job.artifact.ref == nil)
        assert(type(final.job.artifact.released_at) == 'number')
        assert(next(artifacts.artifacts) == nil)

        local persisted = control.namespaces['update/jobs'][job.job_id]
        assert(type(persisted) == 'table')
        assert(persisted.state == 'succeeded')
        assert(persisted.artifact_ref == nil)
        assert(type(persisted.artifact_released_at) == 'number')
    end, { timeout = 4.0 })
end

return T
