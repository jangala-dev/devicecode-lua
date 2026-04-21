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

local function bind_device_double(scope, device_conn, versions, opts)
  opts = opts or {}
  local device_get_ep = device_conn:bind({ 'cmd', 'device', 'component', 'get' }, { queue_len = 32 })
  local device_do_ep = device_conn:bind({ 'cmd', 'device', 'component', 'do' }, { queue_len = 32 })

  bind_reply_loop(scope, device_get_ep, function(payload)
    return {
      ok = true,
      component = {
        component = payload.component,
        status = {
          version = versions[payload.component] or 'unknown',
          state = (opts.get_state and opts.get_state[payload.component]) or 'running',
          incarnation = (opts.incarnation and opts.incarnation[payload.component]) or nil,
        },
      },
    }
  end)

  bind_reply_loop(scope, device_do_ep, function(payload)
    if payload.action == 'prepare_update' then
      if opts.prepare_sleep then sleep_mod.sleep(opts.prepare_sleep) end
      return { ok = true, prepared = true }
    elseif payload.action == 'stage_update' then
      local reply = { ok = true, staged = payload.args.artifact_ref }
      if payload.args.expected_version then reply.expected_version = payload.args.expected_version end
      reply.artifact_retention = opts.artifact_retention or 'release'
      return reply
    elseif payload.action == 'commit_update' then
      local component = payload.component
      if opts.commit_version and opts.commit_version[component] then versions[component] = opts.commit_version[component] end
      if opts.incarnation and component and opts.bump_incarnation then
        opts.incarnation[component] = (opts.incarnation[component] or 0) + 1
      end
      return { ok = true, started = true }
    end
    return nil, 'unsupported_action'
  end)

end

local function bind_fabric_transfer_double(scope, conn)
  local transfer_ep = conn:bind({ 'cmd', 'fabric', 'transfer' }, { queue_len = 32 })
  bind_reply_loop(scope, transfer_ep, function(payload)
    assert(payload.op == 'send_blob')
    assert(type(payload.link_id) == 'string')
    assert(type(payload.source) == 'table')
    if type(payload.receiver) == 'table' then
      assert(type(payload.receiver[1]) == 'string')
    end
    return { ok = true, xfer_id = 'xfer-1', artifact_retention = 'release' }
  end)
end

function T.update_service_creates_starts_commits_and_reconciles_job_via_device_proxy()
  runfibers.run(function(scope)
    local orig_sleep = sleep_mod.sleep
    sleep_mod.sleep = function(dt) return orig_sleep(math.min(dt, 0.01)) end
    fibers.current_scope():finally(function() sleep_mod.sleep = orig_sleep end)

    local bus = busmod.new()
    local caller = bus:connect()
    local control = storagecaps.start_control_store_cap(scope, bus:connect(), {})
    local artifacts = storagecaps.start_artifact_store_cap(scope, bus:connect(), {})
    local versions = { mcu = 'mcu-v0' }
    local inc = { mcu = 1 }
    bind_device_double(scope, bus:connect(), versions, {
      artifact_retention = 'release',
      commit_version = { mcu = 'mcu-v1' },
      incarnation = inc,
      bump_incarnation = true,
    })
    bind_fabric_transfer_double(scope, bus:connect())

    local ok, err = scope:spawn(function()
      update.start(bus:connect(), { name = 'update', env = 'dev' })
    end)
    assert(ok, tostring(err))

    wait_service_running(caller, 'update')

    local created, cerr = caller:call({ 'cmd', 'update', 'job', 'create' }, {
      component = 'mcu',
      artifact = storagecaps.seed_import_path(artifacts, '/tmp/mcu-image-v1.bin', 'mcu-image-v1'),
      expected_version = 'mcu-v1',
      metadata = { channel = 'test' },
    }, { timeout = 0.5 })
    assert(cerr == nil)
    assert(created.ok == true)
    local job = created.job
    assert(type(job.job_id) == 'string')
    assert(job.component == 'mcu')
    assert(type(job.lifecycle.created_seq) == 'number')
    assert(type(job.lifecycle.updated_seq) == 'number')

    local started, serr = caller:call({ 'cmd', 'update', 'job', 'do' }, { op = 'start', job_id = job.job_id }, { timeout = 0.5 })
    assert(serr == nil)
    assert(started.ok == true)
    assert(job.lifecycle.state == 'created')
    assert(type(job.artifact.ref) == 'string')

    assert(probe.wait_until(function()
      local okp, payload = safe.pcall(function()
        return probe.wait_payload(caller, { 'state', 'update', 'jobs', job.job_id }, { timeout = 0.02 })
      end)
      return okp and type(payload) == 'table' and type(payload.job) == 'table'
        and payload.job.lifecycle.state == 'awaiting_commit'
        and payload.job.artifact.ref == nil and payload.job.artifact.released_at ~= nil
    end, { timeout = 0.75, interval = 0.01 }))
    assert(next(artifacts.artifacts) == nil)

    local committed, perr = caller:call({ 'cmd', 'update', 'job', 'do' }, { op = 'commit', job_id = job.job_id }, { timeout = 1.0 })
    assert(perr == nil)
    assert(committed.ok == true)
    assert(committed.job.lifecycle.state == 'awaiting_commit' or committed.job.lifecycle.state == 'awaiting_return' or committed.job.lifecycle.state == 'succeeded')

    assert(probe.wait_until(function()
      local okp, payload = safe.pcall(function()
        return probe.wait_payload(caller, { 'state', 'update', 'jobs', job.job_id }, { timeout = 0.02 })
      end)
      return okp and type(payload) == 'table' and type(payload.job) == 'table' and payload.job.lifecycle.state == 'succeeded'
    end, { timeout = 0.75, interval = 0.01 }))

    local got, gerr = caller:call({ 'cmd', 'update', 'job', 'get' }, { job_id = job.job_id }, { timeout = 0.5 })
    assert(gerr == nil)
    assert(got.ok == true)
    assert(got.job.lifecycle.state == 'succeeded')
    assert(type(got.job.result) == 'table')
    assert(got.job.result.version == 'mcu-v1')

    assert(type(control.namespaces['update/jobs']) == 'table')
    assert(type(control.namespaces['update/jobs'][job.job_id]) == 'table')
  end, { timeout = 3.0 })
end

function T.update_service_cancels_staged_job_before_commit()
  runfibers.run(function(scope)
    local bus = busmod.new()
    local caller = bus:connect()
    storagecaps.start_control_store_cap(scope, bus:connect(), {})
    local artifacts = storagecaps.start_artifact_store_cap(scope, bus:connect(), {})
    bind_device_double(scope, bus:connect(), { mcu = 'mcu-v0' }, { artifact_retention = 'release' })
    bind_fabric_transfer_double(scope, bus:connect())

    local ok, err = scope:spawn(function()
      update.start(bus:connect(), { name = 'update', env = 'dev' })
    end)
    assert(ok, tostring(err))

    wait_service_running(caller, 'update')

    local created, cerr = caller:call({ 'cmd', 'update', 'job', 'create' }, {
      component = 'mcu', artifact = storagecaps.seed_import_path(artifacts, '/tmp/mcu-image.bin', 'mcu-image')
    }, { timeout = 0.5 })
    assert(cerr == nil)
    local job = created.job

    local started, serr = caller:call({ 'cmd', 'update', 'job', 'do' }, { op = 'start', job_id = job.job_id }, { timeout = 0.5 })
    assert(serr == nil)
    assert(started.ok == true)

    assert(probe.wait_until(function()
      local okp, state = safe.pcall(function()
        return probe.wait_payload(caller, { 'state', 'update', 'jobs', job.job_id }, { timeout = 0.02 })
      end)
      return okp and type(state) == 'table' and type(state.job) == 'table' and state.job.lifecycle.state == 'awaiting_commit'
    end, { timeout = 0.75, interval = 0.01 }))

    local cancelled, derr = caller:call({ 'cmd', 'update', 'job', 'do' }, { op = 'cancel', job_id = job.job_id }, { timeout = 0.5 })
    assert(derr == nil)
    assert(cancelled.ok == true)
    assert(cancelled.job.lifecycle.state == 'cancelled')
  end, { timeout = 3.0 })
end

function T.update_service_applies_per_component_artifact_storage_policy()
  runfibers.run(function(scope)
    local bus = busmod.new()
    local caller = bus:connect()
    local control = storagecaps.start_control_store_cap(scope, bus:connect(), {})
    local artifacts = storagecaps.start_artifact_store_cap(scope, bus:connect(), { durable_enabled = true })
    bind_device_double(scope, bus:connect(), { cm5 = 'cm5-v0', mcu = 'mcu-v0' }, { artifact_retention = 'keep' })

    local cfg_conn = bus:connect()
    cfg_conn:retain({ 'cfg', 'update' }, {
      schema = 'devicecode.config/update/1',
      artifacts = {
        default_policy = 'transient_only',
        policies = {
          cm5 = 'prefer_durable',
          mcu = 'transient_only',
        },
      },
    })

    local ok, err = scope:spawn(function()
      update.start(bus:connect(), { name = 'update', env = 'dev' })
    end)
    assert(ok, tostring(err))

    wait_service_running(caller, 'update')
    sleep_mod.sleep(0.05)

    local cm5_created = assert(caller:call({ 'cmd', 'update', 'job', 'create' }, {
      component = 'cm5', artifact = storagecaps.seed_import_path(artifacts, '/tmp/cm5-image.bin', 'cm5-image')
    }, { timeout = 0.5 }))
    local mcu_created = assert(caller:call({ 'cmd', 'update', 'job', 'create' }, {
      component = 'mcu', artifact = storagecaps.seed_import_path(artifacts, '/tmp/mcu-image.bin', 'mcu-image')
    }, { timeout = 0.5 }))

    local cm5_ref = cm5_created.job.artifact.ref
    local mcu_ref = mcu_created.job.artifact.ref
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
    sleep_mod.sleep = function(dt) return orig_sleep(math.min(dt, 0.01)) end
    fibers.current_scope():finally(function() sleep_mod.sleep = orig_sleep end)

    local bus = busmod.new()
    local caller = bus:connect()
    storagecaps.start_control_store_cap(scope, bus:connect(), {})
    local artifacts = storagecaps.start_artifact_store_cap(scope, bus:connect(), {})
    bind_device_double(scope, bus:connect(), { cm5 = 'cm5-v0', mcu = 'mcu-v0' }, {
      prepare_sleep = 0.1,
      artifact_retention = 'release',
    })
    bind_fabric_transfer_double(scope, bus:connect())

    local ok, err = scope:spawn(function()
      update.start(bus:connect(), { name = 'update', env = 'dev' })
    end)
    assert(ok, tostring(err))
    wait_service_running(caller, 'update')

    local j1 = assert(caller:call({ 'cmd', 'update', 'job', 'create' }, { component = 'mcu', artifact = storagecaps.seed_import_path(artifacts, '/tmp/a.bin', 'a') }, { timeout = 0.5 })).job
    local j2 = assert(caller:call({ 'cmd', 'update', 'job', 'create' }, { component = 'cm5', artifact = storagecaps.seed_import_path(artifacts, '/tmp/b.bin', 'b') }, { timeout = 0.5 })).job
    assert(j1.lifecycle.state == 'created')
    assert(j2.lifecycle.state == 'created')

    local s1, s1err = caller:call({ 'cmd', 'update', 'job', 'do' }, { op = 'start', job_id = j1.job_id }, { timeout = 0.5 })
    assert(s1err == nil)
    assert(s1.ok == true)

    local s2, s2err = caller:call({ 'cmd', 'update', 'job', 'do' }, { op = 'start', job_id = j2.job_id }, { timeout = 0.5 })
    assert(s2 == nil)
    assert(s2err == 'busy_global')

    local denied, derr = caller:call({ 'cmd', 'update', 'job', 'do' }, { op = 'commit', job_id = j2.job_id }, { timeout = 0.5 })
    assert(denied == nil)
    assert(derr == 'job_not_committable')
    local got2 = assert(caller:call({ 'cmd', 'update', 'job', 'get' }, { job_id = j2.job_id }, { timeout = 0.5 }))
    assert(got2.job.lifecycle.state == 'created' or got2.job.lifecycle.state == 'failed')
  end, { timeout = 3.0 })
end

return T
