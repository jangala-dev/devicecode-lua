local fibers      = require 'fibers'
local busmod      = require 'bus'
local runfibers   = require 'tests.support.run_fibers'
local probe       = require 'tests.support.bus_probe'
local test_diag   = require 'tests.support.test_diag'
local storagecaps = require 'tests.support.storage_caps'
local update_preflight = require 'tests.support.update_preflight'
local update      = require 'services.update'
local sleep_mod   = require 'fibers.sleep'
local safe        = require 'coxpcall'
local cjson       = require 'cjson.safe'

local T = {}


local function u16le(n)
  return string.char(n % 256, math.floor(n / 256) % 256)
end

local function u32le(n)
  return string.char(
    n % 256,
    math.floor(n / 256) % 256,
    math.floor(n / 65536) % 256,
    math.floor(n / 16777216) % 256
  )
end

local function make_dcmcu(opts)
  opts = opts or {}
  local payload = opts.payload or 'PAYLOAD'
  local manifest = {
    schema = 1,
    component = 'mcu',
    target = {
      product_family = 'bigbox',
      hardware_profile = opts.hardware_profile or 'bb-v1-cm5-2',
      mcu_board_family = opts.mcu_board_family or 'rp2354a',
    },
    build = {
      version = opts.version or 'mcu-v1',
      build_id = opts.build_id or '2026.04.24-1',
      image_id = opts.image_id or 'mcu-bigbox-1+2026.04.24-1',
    },
    payload = {
      format = 'raw-bin',
      length = #payload,
      sha256 = opts.sha256 or string.rep('a', 64),
    },
    signing = {
      key_id = 'test-key',
      sig_alg = 'ed25519',
    },
  }
  local manifest_bytes = cjson.encode(manifest)
  local sig = string.rep('S', 64)
  local header = table.concat({
    'DCMCUIMG', u16le(1), u16le(32), u32le(#manifest_bytes), u32le(64), u32le(#payload), u32le(0), u32le(0)
  })
  return header .. manifest_bytes .. sig .. payload
end

local function install_fake_mcu_preflight()
  local restore = update_preflight.install_fake_mcu_preflight()
  fibers.current_scope():finally(restore)
end

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
  return probe.wait_service_running(conn, name, { timeout = 0.75 })
end

local function new_update_diag(scope, bus, caller, control, artifacts, extra)
  return test_diag.start_profile(scope, bus, 'update_stack', {
    conn = caller,
    control = control,
    artifacts = artifacts,
    max_records = 320,
    fabric = { session_fn = false, transfer_fn = false },
    update = { extra_fn = extra },
  })
end

local function bind_device_double(scope, device_conn, versions, opts)
  opts = opts or {}
  local device_get_ep = device_conn:bind({ 'cap', 'device', 'main', 'rpc', 'get-component' }, { queue_len = 32 })
  local eps = {}
  local function bind_action_ep(component, action)
    local ep = device_conn:bind({ 'cap', 'component', component, 'rpc', action }, { queue_len = 32 })
    eps[#eps + 1] = { component = component, action = action, ep = ep }
  end
  for component in pairs(versions) do
    bind_action_ep(component, 'prepare-update')
    bind_action_ep(component, 'stage-update')
    bind_action_ep(component, 'commit-update')
  end

  local function component_payload(component)
    return {
      kind = 'device.component',
      component = component,
      available = true,
      ready = true,
      software = {
        version = versions[component] or 'unknown',
        image_id = versions[component] or 'unknown',
        boot_id = (opts.boot_id and opts.boot_id[component]) or nil,
      },
      updater = {
        state = (opts.get_state and opts.get_state[component]) or 'running',
      },
      actions = { ['prepare-update'] = true, ['stage-update'] = true, ['commit-update'] = true },
      source = { kind = 'member', member = component, member_class = component },
    }
  end

  local function publish_component(component)
    device_conn:retain({ 'state', 'device', 'component', component }, component_payload(component))
  end
  for component in pairs(versions) do publish_component(component) end

  bind_reply_loop(scope, device_get_ep, function(payload)
    if opts.calls then opts.calls[#opts.calls + 1] = { kind = 'get', req = payload } end
    return component_payload(payload.component)
  end)

  local function handle_component_action(component, action, payload)
    if opts.calls then opts.calls[#opts.calls + 1] = { kind = 'do', component = component, action = action, req = payload } end
    if action == 'prepare-update' then
      if opts.prepare_sleep then sleep_mod.sleep(opts.prepare_sleep) end
      return { ok = true, prepared = true }
    elseif action == 'stage-update' then
      local reply = { ok = true, staged = payload.artifact_ref }
      if payload.expected_image_id then reply.expected_image_id = payload.expected_image_id end
      reply.artifact_retention = opts.artifact_retention or 'release'
      return reply
    elseif action == 'commit-update' then
      if opts.commit_version and opts.commit_version[component] then versions[component] = opts.commit_version[component] end
      if opts.boot_id and component and opts.bump_boot_id then
        opts.boot_id[component] = tostring((opts.boot_id[component] or component .. '-boot') .. '-next')
      end
      publish_component(component)
      return { ok = true, started = true }
    end
    return nil, 'unsupported_action'
  end
  for _, rec in ipairs(eps) do
    bind_reply_loop(scope, rec.ep, function(payload)
      return handle_component_action(rec.component, rec.action, payload)
    end)
  end
end

local function bind_fabric_transfer_double(scope, conn, calls)
  local transfer_ep = conn:bind({ 'cap', 'transfer-manager', 'main', 'rpc', 'send-blob' }, { queue_len = 32 })
  bind_reply_loop(scope, transfer_ep, function(payload)
    if calls then calls[#calls + 1] = payload end
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
    install_fake_mcu_preflight()
    install_fake_mcu_preflight()
    local orig_sleep = sleep_mod.sleep
    sleep_mod.sleep = function(dt) return orig_sleep(math.min(dt, 0.01)) end
    fibers.current_scope():finally(function() sleep_mod.sleep = orig_sleep end)

    local bus = busmod.new()
    local caller = bus:connect()
    local control = storagecaps.start_control_store_cap(scope, bus:connect(), {})
    local artifacts = storagecaps.start_artifact_store_cap(scope, bus:connect(), {})
    local versions = { mcu = 'mcu-v0' }
    local boot = { mcu = 'boot-1' }
    local device_calls = {}
    local fabric_calls = {}

    bind_device_double(scope, bus:connect(), versions, {
      artifact_retention = 'release',
      commit_version = { mcu = 'mcu-v1' },
      boot_id = boot,
      bump_boot_id = true,
      calls = device_calls,
    })

    -- This is no longer exercised directly by update in this unit test,
    -- but we keep it bound so we can assert that update did not bypass device.
    bind_fabric_transfer_double(scope, bus:connect(), fabric_calls)

    local job
    local diag = new_update_diag(scope, bus, caller, control, artifacts, function()
      if job and job.job_id then
        return test_diag.retained_fn(caller, { 'state', 'workflow', 'update-job', job.job_id })()
      end
      return { pending = true }
    end)
    test_diag.add_calls(diag, 'device_calls', device_calls)
    test_diag.add_calls(diag, 'fabric_calls', fabric_calls)

    local function ensure(cond, message)
      if not cond then diag:fail(message) end
    end

    local ok, err = scope:spawn(function()
      update.start(bus:connect(), { name = 'update', env = 'dev' })
    end)
    if not ok then diag:fail('failed to spawn update service: ' .. tostring(err)) end

    wait_service_running(caller, 'update')

    local created, cerr = caller:call({ 'cap', 'update-manager', 'main', 'rpc', 'create-job' }, {
      component = 'mcu',
      artifact = {
        kind = 'import_path',
        path = storagecaps.seed_import_path(artifacts, '/tmp/mcu-image-v1.bin', 'mcu-image-v1'),
      },
      expected_image_id = 'mcu-v1',
      metadata = { channel = 'test' },
    }, { timeout = 0.5 })

    ensure(cerr == nil, 'expected create call to succeed')
    ensure(created and created.ok == true, 'expected create response ok=true')
    ensure(created.job.artifact.expected_image_id == 'mcu-v1', 'expected canonical expected_image_id on job')
    job = created.job
    ensure(type(job.job_id) == 'string', 'expected string job_id')
    ensure(job.component == 'mcu', 'expected component=mcu')
    ensure(type(job.lifecycle.created_seq) == 'number', 'expected created_seq')
    ensure(type(job.lifecycle.updated_seq) == 'number', 'expected updated_seq')

    local started, serr = caller:call({ 'cap', 'update-manager', 'main', 'rpc', 'start-job' }, {
      job_id = job.job_id,
    }, { timeout = 0.5 })

    ensure(serr == nil, 'expected start call to succeed')
    ensure(started and started.ok == true, 'expected start response ok=true')
    ensure(job.lifecycle.state == 'created', 'expected local job copy still in created state')
    ensure(type(job.artifact.ref) == 'string', 'expected artifact ref on created job')

    probe.wait_update_job(caller, job.job_id, function(payload)
      return payload.job.lifecycle.state == 'awaiting_commit'
        and payload.job.artifact.ref == nil
        and payload.job.artifact.released_at ~= nil
    end, { timeout = 0.75, describe = function() return diag:render('job never reached awaiting_commit with released artifact') end })

    ensure(next(artifacts.artifacts) == nil, 'expected transient artifact to be released after staging')

    local committed, perr = caller:call({ 'cap', 'update-manager', 'main', 'rpc', 'commit-job' }, {
      job_id = job.job_id,
    }, { timeout = 1.0 })

    ensure(perr == nil, 'expected commit call to succeed')
    ensure(committed and committed.ok == true, 'expected commit response ok=true')
    ensure(
      committed.job
        and (
          committed.job.lifecycle.state == 'awaiting_commit'
          or committed.job.lifecycle.state == 'awaiting_return'
          or committed.job.lifecycle.state == 'succeeded'
        ),
      'expected commit response state to be awaiting_commit/awaiting_return/succeeded'
    )

    probe.wait_update_job(caller, job.job_id, function(payload)
      return payload.job.lifecycle.state == 'succeeded'
    end, { timeout = 0.75, describe = function() return diag:render('job never reached succeeded after commit') end })

    local got, gerr = caller:call({ 'cap', 'update-manager', 'main', 'rpc', 'get-job' }, {
      job_id = job.job_id,
    }, { timeout = 0.5 })

    ensure(gerr == nil, 'expected get call to succeed')
    ensure(got and got.ok == true, 'expected get response ok=true')
    ensure(got.job.lifecycle.state == 'succeeded', 'expected final job state succeeded')
    ensure(type(got.job.result) == 'table', 'expected result table')
    ensure(got.job.result.image_id == 'mcu-v1', 'expected final version mcu-v1')

    local get_calls = 0
    local do_calls = 0
    local actions = {}

    for _, call in ipairs(device_calls) do
      if call.kind == 'get' then
        get_calls = get_calls + 1
      elseif call.kind == 'do' then
        do_calls = do_calls + 1
        actions[#actions + 1] = call.action
      end
    end

    ensure(get_calls == 0, 'expected no device get calls in observer-driven mode, got ' .. tostring(get_calls))
    ensure(do_calls == 3, 'expected exactly three device action calls, got ' .. tostring(do_calls))
    ensure(actions[1] == 'prepare-update', 'expected first device action prepare-update, got ' .. tostring(actions[1]))
    ensure(actions[2] == 'stage-update', 'expected second device action stage-update, got ' .. tostring(actions[2]))
    ensure(actions[3] == 'commit-update', 'expected third device action commit-update, got ' .. tostring(actions[3]))

    ensure(#fabric_calls == 0, 'expected no direct fabric calls from update, got ' .. tostring(#fabric_calls))

    ensure(type(control.namespaces['update/jobs']) == 'table', 'expected update/jobs namespace in control store')
    ensure(type(control.namespaces['update/jobs'][job.job_id]) == 'table', 'expected persisted job in control store')
  end, { timeout = 3.0 })
end

function T.update_service_cancels_staged_job_before_commit()
  runfibers.run(function(scope)
    install_fake_mcu_preflight()
    install_fake_mcu_preflight()
    local bus = busmod.new()
    local caller = bus:connect()
    local control = storagecaps.start_control_store_cap(scope, bus:connect(), {})
    local artifacts = storagecaps.start_artifact_store_cap(scope, bus:connect(), {})
    local diag = new_update_diag(scope, bus, caller, control, artifacts)
    bind_device_double(scope, bus:connect(), { mcu = 'mcu-v0' }, { artifact_retention = 'release' })
    bind_fabric_transfer_double(scope, bus:connect())

    local ok, err = scope:spawn(function()
      update.start(bus:connect(), { name = 'update', env = 'dev' })
    end)
    assert(ok, tostring(err))

    wait_service_running(caller, 'update')

    local created, cerr = caller:call({ 'cap', 'update-manager', 'main', 'rpc', 'create-job' }, {
      component = 'mcu', artifact = { kind = 'import_path', path = storagecaps.seed_import_path(artifacts, '/tmp/mcu-image.bin', 'mcu-image') }
    }, { timeout = 0.5 })
    assert(cerr == nil)
    local job = created.job

    local started, serr = caller:call({ 'cap', 'update-manager', 'main', 'rpc', 'start-job' }, { job_id = job.job_id }, { timeout = 0.5 })
    assert(serr == nil)
    assert(started.ok == true)

    probe.wait_update_job(caller, job.job_id, function(payload)
      return payload.job.lifecycle.state == 'awaiting_commit'
    end, { timeout = 0.75 })

    local cancelled, derr = caller:call({ 'cap', 'update-manager', 'main', 'rpc', 'cancel-job' }, { job_id = job.job_id }, { timeout = 0.5 })
    assert(derr == nil)
    assert(cancelled.ok == true)
    assert(cancelled.job.lifecycle.state == 'cancelled')
  end, { timeout = 3.0 })
end

function T.update_service_applies_per_component_artifact_storage_policy()
  runfibers.run(function(scope)
    install_fake_mcu_preflight()
    install_fake_mcu_preflight()
    local bus = busmod.new()
    local caller = bus:connect()
    local control = storagecaps.start_control_store_cap(scope, bus:connect(), {})
    local artifacts = storagecaps.start_artifact_store_cap(scope, bus:connect(), { durable_enabled = true })
    local diag = new_update_diag(scope, bus, caller, control, artifacts)
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

    local cm5_created = assert(caller:call({ 'cap', 'update-manager', 'main', 'rpc', 'create-job' }, {
      component = 'cm5', artifact = { kind = 'import_path', path = storagecaps.seed_import_path(artifacts, '/tmp/cm5-image.bin', 'cm5-image') }
    }, { timeout = 0.5 }))
    local mcu_created = assert(caller:call({ 'cap', 'update-manager', 'main', 'rpc', 'create-job' }, {
      component = 'mcu', artifact = { kind = 'import_path', path = storagecaps.seed_import_path(artifacts, '/tmp/mcu-image.bin', 'mcu-image') }
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
    install_fake_mcu_preflight()
    install_fake_mcu_preflight()
    local orig_sleep = sleep_mod.sleep
    sleep_mod.sleep = function(dt) return orig_sleep(math.min(dt, 0.01)) end
    fibers.current_scope():finally(function() sleep_mod.sleep = orig_sleep end)

    local bus = busmod.new()
    local caller = bus:connect()
    local control = storagecaps.start_control_store_cap(scope, bus:connect(), {})
    local artifacts = storagecaps.start_artifact_store_cap(scope, bus:connect(), {})
    local diag = new_update_diag(scope, bus, caller, control, artifacts)
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

    local j1 = assert(caller:call({ 'cap', 'update-manager', 'main', 'rpc', 'create-job' }, { component = 'mcu', artifact = { kind = 'import_path', path = storagecaps.seed_import_path(artifacts, '/tmp/a.bin', 'a') } }, { timeout = 0.5 })).job
    local j2 = assert(caller:call({ 'cap', 'update-manager', 'main', 'rpc', 'create-job' }, { component = 'cm5', artifact = { kind = 'import_path', path = storagecaps.seed_import_path(artifacts, '/tmp/b.bin', 'b') } }, { timeout = 0.5 })).job
    assert(j1.lifecycle.state == 'created')
    assert(j2.lifecycle.state == 'created')

    local s1, s1err = caller:call({ 'cap', 'update-manager', 'main', 'rpc', 'start-job' }, { job_id = j1.job_id }, { timeout = 0.5 })
    assert(s1err == nil)
    assert(s1.ok == true)

    local s2, s2err = caller:call({ 'cap', 'update-manager', 'main', 'rpc', 'start-job' }, { job_id = j2.job_id }, { timeout = 0.5 })
    assert(s2 == nil)
    assert(s2err == 'busy_global')

    local denied, derr = caller:call({ 'cap', 'update-manager', 'main', 'rpc', 'commit-job' }, { job_id = j2.job_id }, { timeout = 0.5 })
    assert(denied == nil)
    assert(derr == 'job_not_committable')
    local got2 = assert(caller:call({ 'cap', 'update-manager', 'main', 'rpc', 'get-job' }, { job_id = j2.job_id }, { timeout = 0.5 }))
    assert(got2.job.lifecycle.state == 'created' or got2.job.lifecycle.state == 'failed')
  end, { timeout = 3.0 })
end

function T.update_service_supports_ref_artifacts_and_auto_start()
  runfibers.run(function(scope)
    install_fake_mcu_preflight()
    install_fake_mcu_preflight()
    local bus = busmod.new()
    local caller = bus:connect()
    local control = storagecaps.start_control_store_cap(scope, bus:connect(), {})
    local artifacts = storagecaps.start_artifact_store_cap(scope, bus:connect(), {})
    local diag = new_update_diag(scope, bus, caller, control, artifacts)
    local versions = { mcu = 'mcu-v0' }
    local boot = { mcu = 'boot-1' }
    bind_device_double(scope, bus:connect(), versions, {
      artifact_retention = 'release',
      commit_version = { mcu = 'mcu-v1' },
      boot_id = boot,
      bump_boot_id = true,
    })
    bind_fabric_transfer_double(scope, bus:connect())

    local ok, err = scope:spawn(function()
      update.start(bus:connect(), { name = 'update', env = 'dev' })
    end)
    assert(ok, tostring(err))
    wait_service_running(caller, 'update')

    local art_path = storagecaps.seed_import_path(artifacts, '/tmp/upl.bin', 'uploaded-image')
    local imported = assert(caller:call({ 'raw', 'host', 'artifact-store', 'cap', 'artifact-store', 'main', 'rpc', 'import_path' }, { path = art_path, meta = { kind = 'update' }, policy = 'transient_only' }, { timeout = 0.5 }))
    local art = imported.reason

    local created, cerr = caller:call({ 'cap', 'update-manager', 'main', 'rpc', 'create-job' }, {
      component = 'mcu',
      artifact = { kind = 'ref', ref = art:ref() },
      expected_image_id = 'mcu-v1',
      options = { auto_start = true },
    }, { timeout = 0.5 })
    assert(cerr == nil)
    assert(created.ok == true)
    assert(created.job.artifact.expected_image_id == 'mcu-v1')
    local job = created.job

    probe.wait_update_job(caller, job.job_id, function(payload)
      return payload.job.lifecycle.state == 'awaiting_commit'
    end, { timeout = 0.75 })
  end, { timeout = 3.0 })
end

function T.update_service_marks_bundled_hold_after_manual_mcu_success()
  runfibers.run(function(scope)
    install_fake_mcu_preflight()
    install_fake_mcu_preflight()
    local orig_sleep = sleep_mod.sleep
    sleep_mod.sleep = function(dt) return orig_sleep(math.min(dt, 0.01)) end
    fibers.current_scope():finally(function() sleep_mod.sleep = orig_sleep end)

    local bus = busmod.new()
    local caller = bus:connect()
    local control = storagecaps.start_control_store_cap(scope, bus:connect(), {})
    local artifacts = storagecaps.start_artifact_store_cap(scope, bus:connect(), {})
    local cfg_conn = bus:connect()
    local dcmcu_path = '/rom/mcu/current.dcmcu'

    storagecaps.seed_import_path(
      artifacts,
      dcmcu_path,
      make_dcmcu({
        version = 'mcu-v1-manual',
        image_id = 'mcu-v1-manual',
        sha256 = string.rep('b', 64),
      })
    )

    cfg_conn:retain({ 'cfg', 'update' }, {
      schema = 'devicecode.config/update/1',
      bundled = {
        components = {
          mcu = {
            enabled = true,
            follow_mode_default = 'hold',
            auto_start = true,
            auto_commit = true,
            source = { kind = 'bundled', path = dcmcu_path },
            target = {
              product_family = 'bigbox',
              hardware_profile = 'bb-v1-cm5-2',
              mcu_board_family = 'rp2354a',
            },
          },
        },
      },
    })

    bind_device_double(scope, bus:connect(), { mcu = 'mcu-v0' }, {
      artifact_retention = 'release',
      commit_version = { mcu = 'mcu-v1-manual' },
      boot_id = { mcu = 'boot-1' },
      bump_boot_id = true,
    })

    local ok, err = scope:spawn(function()
      update.start(bus:connect(), { name = 'update', env = 'dev' })
    end)
    assert(ok, tostring(err))
    wait_service_running(caller, 'update')

    local created = assert(caller:call({ 'cap', 'update-manager', 'main', 'rpc', 'create-job' }, {
      component = 'mcu',
      artifact = { kind = 'import_path', path = storagecaps.seed_import_path(artifacts, '/tmp/manual.bin', 'manual') },
      expected_image_id = 'mcu-v1-manual',
      metadata = { source = 'ui_upload' },
    }, { timeout = 0.5 }))
    local job_id = created.job.job_id
    assert(assert(caller:call({ 'cap', 'update-manager', 'main', 'rpc', 'start-job' }, { job_id = job_id }, { timeout = 0.5 })).ok == true)
    probe.wait_update_job(caller, job_id, function(payload)
      return payload.job.lifecycle.state == 'awaiting_commit'
    end, { timeout = 0.75 })
    assert(assert(caller:call({ 'cap', 'update-manager', 'main', 'rpc', 'commit-job' }, { job_id = job_id }, { timeout = 1.0 })).ok == true)
    probe.wait_update_job(caller, job_id, function(payload)
      return payload.job.lifecycle.state == 'succeeded'
    end, { timeout = 0.75 })
    probe.wait_update_component(caller, 'mcu', function(payload)
      return payload.follow_mode == 'hold'
        and (payload.last_result == 'manual_success_hold' or payload.last_result == 'held')
    end, { timeout = 0.75 })
  end, { timeout = 3.0 })
end

return T
