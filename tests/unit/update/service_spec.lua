local fibers      = require 'fibers'
local busmod      = require 'bus'
local runfibers   = require 'tests.support.run_fibers'
local probe       = require 'tests.support.bus_probe'
local storagecaps = require 'tests.support.storage_caps'
local update      = require 'services.update'
local sleep_mod   = require 'fibers.sleep'
local safe        = require 'coxpcall'

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

local function wait_service_running(conn, name)
  assert(probe.wait_until(function()
    local okp, payload = safe.pcall(function()
      return probe.wait_payload(conn, { 'svc', name, 'status' }, { timeout = 0.02 })
    end)
    return okp and type(payload) == 'table' and payload.state == 'running'
  end, { timeout = 0.75, interval = 0.01 }))
end

function T.update_service_creates_applies_and_reconciles_job_via_device_proxy()
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
    local device_conn = bus:connect()

    local versions = { mcu = 'mcu-v0' }
    local device_status_ep = device_conn:bind({ 'cmd', 'device', 'component', 'status' }, { queue_len = 32 })
    local device_update_ep = device_conn:bind({ 'cmd', 'device', 'component', 'update' }, { queue_len = 32 })

    bind_reply_loop(scope, device_status_ep, function(payload)
      return { ok = true, component = payload.component, state = { version = versions[payload.component] or 'unknown' } }
    end)
    bind_reply_loop(scope, device_update_ep, function(payload)
      if payload.op == 'prepare' then
        return { ok = true, prepared = true }
      elseif payload.op == 'stage' then
        assert(type(payload.args.artifact_ref) == 'string')
        return { ok = true, staged = payload.args.artifact_ref, expected_version = payload.args.expected_version }
      elseif payload.op == 'commit' then
        versions[payload.component] = 'mcu-v1'
        return { ok = true, started = true }
      end
      return nil, 'unsupported_op'
    end)

    local ok, err = scope:spawn(function()
      update.start(bus:connect(), { name = 'update', env = 'dev' })
    end)
    assert(ok, tostring(err))

    wait_service_running(caller, 'update')

    local created, cerr = caller:call({ 'cmd', 'update', 'job', 'create' }, {
      target = 'mcu',
      artifact_data = 'mcu-image-v1',
      expected_version = 'mcu-v1',
      metadata = { channel = 'test' },
      approval = 'manual',
    }, { timeout = 0.5 })
    assert(cerr == nil)
    assert(created.ok == true)
    local job = created.job
    assert(type(job.job_id) == 'string')
    assert(job.state == 'available')
    assert(type(job.artifact_ref) == 'string')

    local applied, aerr = caller:call({ 'cmd', 'update', 'job', 'apply_now' }, { job_id = job.job_id }, { timeout = 1.0 })
    assert(aerr == nil)
    assert(applied.ok == true)
    assert(type(applied.job) == 'table')
    assert(applied.job.state == 'queued')
    assert(type(applied.job.artifact_ref) == 'string')

    assert(probe.wait_until(function()
      local okp, state = safe.pcall(function()
        return probe.wait_payload(caller, { 'state', 'update', 'jobs', job.job_id }, { timeout = 0.02 })
      end)
      return okp and type(state) == 'table' and type(state.job) == 'table' and state.job.state == 'awaiting_approval'
        and state.job.artifact_ref == nil and state.job.artifact_released_at ~= nil
    end, { timeout = 0.75, interval = 0.01 }))
    assert(next(artifacts.artifacts) == nil)

    local approved, perr = caller:call({ 'cmd', 'update', 'job', 'approve' }, { job_id = job.job_id }, { timeout = 1.0 })
    assert(perr == nil)
    assert(approved.ok == true)
    assert(approved.job.state == 'queued')

    assert(probe.wait_until(function()
      local okp, state = safe.pcall(function()
        return probe.wait_payload(caller, { 'state', 'update', 'jobs', job.job_id }, { timeout = 0.02 })
      end)
      return okp and type(state) == 'table' and type(state.job) == 'table' and state.job.state == 'succeeded'
    end, { timeout = 0.75, interval = 0.01 }))

    local got, gerr = caller:call({ 'cmd', 'update', 'job', 'get' }, { job_id = job.job_id }, { timeout = 0.5 })
    assert(gerr == nil)
    assert(got.ok == true)
    assert(got.job.state == 'succeeded')
    assert(type(got.job.result) == 'table')
    assert(got.job.result.version == 'mcu-v1')

    assert(type(control.namespaces['update/jobs']) == 'table')
    assert(type(control.namespaces['update/jobs'][job.job_id]) == 'table')
  end, { timeout = 3.0 })
end

function T.update_service_defers_manual_job_without_applying()
  runfibers.run(function(scope)
    local bus = busmod.new()
    local caller = bus:connect()
    storagecaps.start_control_store_cap(scope, bus:connect(), {})
    storagecaps.start_artifact_store_cap(scope, bus:connect(), {})
    local device_conn = bus:connect()

    local device_status_ep = device_conn:bind({ 'cmd', 'device', 'component', 'status' }, { queue_len = 32 })
    local device_update_ep = device_conn:bind({ 'cmd', 'device', 'component', 'update' }, { queue_len = 32 })

    bind_reply_loop(scope, device_status_ep, function(payload)
      return { ok = true, component = payload.component, state = { version = 'mcu-v0' } }
    end)
    bind_reply_loop(scope, device_update_ep, function(payload)
      if payload.op == 'prepare' then
        return { ok = true, prepared = true }
      elseif payload.op == 'stage' then
        return { ok = true, staged = payload.args.artifact_ref }
      elseif payload.op == 'commit' then
        return { ok = true, started = true }
      end
      return nil, 'unsupported_op'
    end)

    local ok, err = scope:spawn(function()
      update.start(bus:connect(), { name = 'update', env = 'dev' })
    end)
    assert(ok, tostring(err))

    wait_service_running(caller, 'update')

    local created, cerr = caller:call({ 'cmd', 'update', 'job', 'create' }, {
      target = 'mcu', artifact_data = 'mcu-image', approval = 'manual'
    }, { timeout = 0.5 })
    assert(cerr == nil)
    local job = created.job

    local applied, aerr = caller:call({ 'cmd', 'update', 'job', 'apply_now' }, { job_id = job.job_id }, { timeout = 1.0 })
    assert(aerr == nil)
    assert(applied.ok == true)
    assert(applied.job.state == 'queued')

    assert(probe.wait_until(function()
      local okp, state = safe.pcall(function()
        return probe.wait_payload(caller, { 'state', 'update', 'jobs', job.job_id }, { timeout = 0.02 })
      end)
      return okp and type(state) == 'table' and type(state.job) == 'table' and state.job.state == 'awaiting_approval'
    end, { timeout = 0.75, interval = 0.01 }))

    local deferred, derr = caller:call({ 'cmd', 'update', 'job', 'defer' }, { job_id = job.job_id }, { timeout = 0.5 })
    assert(derr == nil)
    assert(deferred.ok == true)
    assert(deferred.job.state == 'deferred')
  end, { timeout = 3.0 })
end

function T.update_service_applies_per_target_artifact_storage_policy()
  runfibers.run(function(scope)
    local bus = busmod.new()
    local caller = bus:connect()
    local control = storagecaps.start_control_store_cap(scope, bus:connect(), {})
    local artifacts = storagecaps.start_artifact_store_cap(scope, bus:connect(), { durable_enabled = true })
    local device_conn = bus:connect()

    local device_status_ep = device_conn:bind({ 'cmd', 'device', 'component', 'status' }, { queue_len = 32 })
    local device_update_ep = device_conn:bind({ 'cmd', 'device', 'component', 'update' }, { queue_len = 32 })

    bind_reply_loop(scope, device_status_ep, function(payload)
      return { ok = true, component = payload.component, state = { version = payload.component .. '-v0' } }
    end)
    bind_reply_loop(scope, device_update_ep, function(payload)
      if payload.op == 'prepare' then
        return { ok = true, prepared = true }
      elseif payload.op == 'stage' then
        return { ok = true, staged = payload.args.artifact_ref, artifact_retention = 'keep' }
      elseif payload.op == 'commit' then
        return { ok = true, started = true }
      end
      return nil, 'unsupported_op'
    end)

    local cfg_conn = bus:connect()
    cfg_conn:retain({ 'cfg', 'update' }, {
      artifact_policy_default = 'transient_only',
      artifact_policies = {
        cm5 = 'prefer_durable',
        mcu = 'transient_only',
      },
    })

    local ok, err = scope:spawn(function()
      update.start(bus:connect(), { name = 'update', env = 'dev' })
    end)
    assert(ok, tostring(err))

    wait_service_running(caller, 'update')
    sleep_mod.sleep(0.05)

    local cm5_created = assert(caller:call({ 'cmd', 'update', 'job', 'create' }, {
      target = 'cm5', artifact_data = 'cm5-image'
    }, { timeout = 0.5 }))
    local mcu_created = assert(caller:call({ 'cmd', 'update', 'job', 'create' }, {
      target = 'mcu', artifact_data = 'mcu-image'
    }, { timeout = 0.5 }))

    local cm5_ref = cm5_created.job.artifact_ref
    local mcu_ref = mcu_created.job.artifact_ref
    assert(type(cm5_ref) == 'string' and type(mcu_ref) == 'string')
    assert(type(artifacts.artifacts[cm5_ref]) == 'table')
    assert(type(artifacts.artifacts[mcu_ref]) == 'table')
    assert(artifacts.artifacts[cm5_ref].durability == 'durable')
    assert(artifacts.artifacts[mcu_ref].durability == 'transient')

    assert(type(control.namespaces['update/jobs']) == 'table')
    assert(type(control.namespaces['update/jobs'][cm5_created.job.job_id]) == 'table')
    assert(type(control.namespaces['update/jobs'][mcu_created.job.job_id]) == 'table')
  end, { timeout = 3.0 })
end


function T.update_service_rejects_second_active_job_globally()
  runfibers.run(function(scope)
    local orig_sleep = sleep_mod.sleep
    sleep_mod.sleep = function(dt)
      return orig_sleep(math.min(dt, 0.01))
    end
    fibers.current_scope():finally(function() sleep_mod.sleep = orig_sleep end)

    local bus = busmod.new()
    local caller = bus:connect()
    storagecaps.start_control_store_cap(scope, bus:connect(), {})
    storagecaps.start_artifact_store_cap(scope, bus:connect(), {})
    local device_conn = bus:connect()

    local device_status_ep = device_conn:bind({ 'cmd', 'device', 'component', 'status' }, { queue_len = 32 })
    local device_update_ep = device_conn:bind({ 'cmd', 'device', 'component', 'update' }, { queue_len = 32 })

    bind_reply_loop(scope, device_status_ep, function(payload)
      return { ok = true, component = payload.component, state = { version = payload.component .. '-v0' } }
    end)
    bind_reply_loop(scope, device_update_ep, function(payload)
      if payload.op == 'prepare' then
        sleep_mod.sleep(0.1)
        return { ok = true, prepared = true }
      elseif payload.op == 'stage' then
        return { ok = true, staged = payload.args.artifact_ref }
      elseif payload.op == 'commit' then
        return { ok = true, started = true }
      end
      return nil, 'unsupported_op'
    end)

    local ok, err = scope:spawn(function()
      update.start(bus:connect(), { name = 'update', env = 'dev' })
    end)
    assert(ok, tostring(err))
    wait_service_running(caller, 'update')

    local j1 = assert(caller:call({ 'cmd', 'update', 'job', 'create' }, { target = 'mcu', artifact_data = 'a', approval = 'manual' }, { timeout = 0.5 })).job
    local j2 = assert(caller:call({ 'cmd', 'update', 'job', 'create' }, { target = 'cm5', artifact_data = 'b', approval = 'manual' }, { timeout = 0.5 })).job

    local applied, aerr = caller:call({ 'cmd', 'update', 'job', 'apply_now' }, { job_id = j1.job_id }, { timeout = 1.0 })
    assert(aerr == nil)
    assert(applied.ok == true)

    local denied, derr = caller:call({ 'cmd', 'update', 'job', 'apply_now' }, { job_id = j2.job_id }, { timeout = 0.5 })
    assert(denied == nil)
    assert(derr == 'busy_global')
  end, { timeout = 3.0 })
end

return T
