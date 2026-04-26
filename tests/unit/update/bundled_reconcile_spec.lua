local fibers      = require 'fibers'
local busmod      = require 'bus'
local runfibers   = require 'tests.support.run_fibers'
local probe       = require 'tests.support.bus_probe'
local storagecaps = require 'tests.support.storage_caps'
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

local function bind_device_double(scope, device_conn, versions, opts)
  opts = opts or {}
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
    local not_ready = opts.not_ready and opts.not_ready[component] == true
    return {
      kind = 'device.component',
      component = component,
      available = true,
      ready = (not not_ready),
      software = not_ready and {} or {
        version = versions[component] or 'unknown',
        image_id = (opts.image_ids and opts.image_ids[component]) or nil,
        payload_sha256 = (opts.payload_sha256 and opts.payload_sha256[component]) or nil,
        boot_id = (opts.boot_id and opts.boot_id[component]) or nil,
      },
      updater = not_ready and {} or { state = (opts.get_state and opts.get_state[component]) or 'running' },
      actions = { ['prepare-update'] = true, ['stage-update'] = true, ['commit-update'] = true },
      source = { kind = 'member', member = component, member_class = component },
    }
  end

  local function publish_component(component)
    device_conn:retain({ 'state', 'device', 'component', component }, component_payload(component))
  end
  for component in pairs(versions) do publish_component(component) end

  local function handle_component_action(component, action, payload)
    if opts.calls then opts.calls[#opts.calls + 1] = { kind = 'do', component = component, action = action, req = payload } end
    if action == 'prepare-update' then
      return { ok = true, prepared = true }
    elseif action == 'stage-update' then
      if opts.fail_stage_once then opts.fail_stage_once = false; return nil, 'stage_failed_once' end
      if opts.block_stage_until_released then return nil, 'stage_blocked' end
      return {
        ok = true,
        staged = payload.artifact_ref,
        artifact_retention = 'release',
        expected_image_id = payload.expected_image_id,
      }
    elseif action == 'commit-update' then
      if opts.commit_version and opts.commit_version[component] then versions[component] = opts.commit_version[component] end
      if opts.image_ids and opts.commit_image_id and opts.commit_image_id[component] then opts.image_ids[component] = opts.commit_image_id[component] end
      if opts.payload_sha256 and opts.commit_sha and opts.commit_sha[component] then opts.payload_sha256[component] = opts.commit_sha[component] end
      if opts.boot_id and opts.bump_boot_id then opts.boot_id[component] = tostring((opts.boot_id[component] or component .. '-boot') .. '-next') end
      publish_component(component)
      return { ok = true, started = true }
    end
    return nil, 'unsupported_action'
  end
  for _, rec in ipairs(eps) do
    bind_reply_loop(scope, rec.ep, function(payload) return handle_component_action(rec.component, rec.action, payload) end)
  end

  return publish_component
end

local function wait_service_running(conn)
  assert(probe.wait_until(function()
    local okp, payload = safe.pcall(function()
      return probe.wait_payload(conn, { 'svc', 'update', 'status' }, { timeout = 0.02 })
    end)
    return okp and type(payload) == 'table' and payload.state == 'running' and payload.ready == true
  end, { timeout = 0.75, interval = 0.01 }))
end

local function wait_job_state(conn, state, timeout)
  return probe.wait_until(function()
    local okp, payload = safe.pcall(function()
      return probe.wait_payload(conn, { 'state', 'update', 'summary' }, { timeout = 0.02 })
    end)
    if not okp or type(payload) ~= 'table' or type(payload.jobs) ~= 'table' then
      return false
    end
    for _, job in ipairs(payload.jobs) do
      if type(job) == 'table' and type(job.lifecycle) == 'table' and job.lifecycle.state == state then
        return true
      end
    end
    return false
  end, { timeout = timeout or 1.0, interval = 0.01 })
end

local function wait_bundled(conn, pred, timeout)
  assert(probe.wait_until(function()
    local okp, payload = safe.pcall(function()
      return probe.wait_payload(conn, { 'state', 'update', 'component', 'mcu' }, { timeout = 0.02 })
    end)
    return okp and pred(payload)
  end, { timeout = timeout or 1.0, interval = 0.01 }))
end

local function start_update_scope(parent, bus)
  local s, err = parent:child()
  assert(s, tostring(err))
  local ok, spawn_err = s:spawn(function()
    update.start(bus:connect(), { name = 'update', env = 'dev' })
  end)
  assert(ok, tostring(spawn_err))
  return s
end

function T.bundled_reconcile_auto_runs_and_marks_satisfied_when_current_differs()
  runfibers.run(function(scope)
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
        version = 'mcu-v1',
        image_id = 'mcu-image-1',
        sha256 = string.rep('b', 64),
      })
    )

    cfg_conn:retain({ 'cfg', 'update' }, {
      schema = 'devicecode.config/update/1',
      bundled = {
        components = {
          mcu = {
            enabled = true,
            follow_mode_default = 'auto',
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

    local versions = { cm5 = 'cm5-v2', mcu = 'mcu-v0' }
    local image_ids = { cm5 = 'cm5-release-2', mcu = 'mcu-image-0' }
    local sha = { mcu = string.rep('0', 64) }
    local boot = { cm5 = 'cm5-boot-1', mcu = 'mcu-boot-1' }

    bind_device_double(scope, bus:connect(), versions, {
      image_ids = image_ids,
      payload_sha256 = sha,
      boot_id = boot,
      commit_version = { mcu = 'mcu-v1' },
      commit_image_id = { mcu = 'mcu-image-1' },
      commit_sha = { mcu = string.rep('b', 64) },
      bump_boot_id = true,
    })

    local us = start_update_scope(scope, bus)
    fibers.current_scope():finally(function() us:cancel('shutdown') end)

    wait_service_running(caller)

    wait_bundled(caller, function(payload)
      return type(payload) == 'table'
        and payload.follow_mode == 'auto'
        and payload.sync_state == 'satisfied'
    end, 2.0)

    assert(probe.wait_until(function()
      local jobs = control.namespaces['update/jobs'] or {}
      for _, job in pairs(jobs) do
        if type(job) == 'table' and job.state == 'succeeded' then
          return true
        end
      end
      return false
    end, { timeout = 1.0, interval = 0.01 }))
  end, { timeout = 4.0 })
end

function T.bundled_reconcile_respects_hold_mode_and_does_not_create_job()
  runfibers.run(function(scope)
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
        version = 'mcu-v1',
        image_id = 'mcu-image-1',
        sha256 = string.rep('b', 64),
      })
    )

    control.namespaces['update/state/bundled'] = {
      mcu = { follow_mode = 'hold' }
    }

    cfg_conn:retain({ 'cfg', 'update' }, {
      schema = 'devicecode.config/update/1',
      bundled = {
        components = {
          mcu = {
            enabled = true,
            follow_mode_default = 'auto',
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

    bind_device_double(scope, bus:connect(), { cm5 = 'cm5-v2', mcu = 'mcu-v0' }, {
      image_ids = { cm5 = 'cm5-release-2', mcu = 'mcu-image-0' },
      payload_sha256 = { mcu = string.rep('0', 64) },
      boot_id = { cm5 = 'cm5-boot-1', mcu = 'mcu-boot-1' },
    })

    local us = start_update_scope(scope, bus)
    fibers.current_scope():finally(function() us:cancel('shutdown') end)

    wait_service_running(caller)

    wait_bundled(caller, function(payload)
      return type(payload) == 'table'
        and payload.follow_mode == 'hold'
        and payload.sync_state == 'diverged'
    end, 2.0)

    assert(probe.wait_until(function()
      local jobs = control.namespaces['update/jobs'] or {}
      return next(jobs) == nil
    end, { timeout = 1.0, interval = 0.01 }))
  end, { timeout = 3.0 })
end

function T.bundled_reconcile_waits_for_component_readiness_before_probing_or_running()
  runfibers.run(function(scope)
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
        version = 'mcu-v1',
        image_id = 'mcu-image-1',
        sha256 = string.rep('b', 64),
      })
    )

    cfg_conn:retain({ 'cfg', 'update' }, {
      schema = 'devicecode.config/update/1',
      bundled = {
        components = {
          mcu = {
            enabled = true,
            follow_mode_default = 'auto',
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

    bind_device_double(scope, bus:connect(), { cm5 = 'cm5-v2', mcu = 'mcu-v0' }, {
      image_ids = { cm5 = 'cm5-release-2', mcu = 'mcu-image-0' },
      payload_sha256 = { mcu = string.rep('0', 64) },
      boot_id = { cm5 = 'cm5-boot-1', mcu = 'mcu-boot-1' },
      get_state = { mcu = 'running' },
      not_ready = { mcu = true },
    })

    local us = start_update_scope(scope, bus)
    fibers.current_scope():finally(function() us:cancel('shutdown') end)

    wait_service_running(caller)

    sleep_mod.sleep(0.25)
    assert((control.namespaces['update/jobs'] and next(control.namespaces['update/jobs'])) == nil)
    assert((control.namespaces['update/state/bundled'] and control.namespaces['update/state/bundled'].mcu) == nil)
  end, { timeout = 3.0 })
end

function T.bundled_reconcile_manual_success_hold_marks_satisfied_when_current_matches_desired()
  local rec_saved
  local retained
  local bundled = require 'services.update.bundled_reconcile'
  local inst = bundled.new({
    observer = {
      component_state_for = function(_, component)
        if component == 'mcu' then
          return {
            available = true,
            ready = true,
            software = {
              version = 'mcu-v1',
              image_id = 'mcu-image-1',
              payload_sha256 = string.rep('b', 64),
              boot_id = 'mcu-boot-2',
            },
          }
        end
      end,
    },
    now = function() return 123 end,
    svc = { obs_log = function() end },
    conn = { retain = function(_, _, payload) retained = payload end },
  }, {}, {
    get = function()
      return {
        follow_mode = 'auto',
        desired = {
          image_id = 'mcu-image-1',
          payload_sha256 = string.rep('b', 64),
          version = 'mcu-v1',
        },
      }
    end,
    put = function(_, component, rec)
      assert(component == 'mcu')
      rec_saved = rec
      return true
    end,
  })

  inst:mark_job_success({ component = 'mcu', job_id = 'job-1', metadata = { source = 'ui_upload' } }, {})
  assert(type(rec_saved) == 'table')
  assert(rec_saved.follow_mode == 'hold')
  assert(rec_saved.sync_state == 'satisfied')
  assert(rec_saved.last_result == 'manual_success_hold_satisfied')
  assert(type(retained) == 'table' and retained.sync_state == 'satisfied')
end

function T.bundled_reconcile_retries_after_restart_when_previous_attempt_failed()
  runfibers.run(function(scope)
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
        version = 'mcu-v1',
        image_id = 'mcu-image-1',
        sha256 = string.rep('b', 64),
      })
    )

    cfg_conn:retain({ 'cfg', 'update' }, {
      schema = 'devicecode.config/update/1',
      bundled = {
        components = {
          mcu = {
            enabled = true,
            follow_mode_default = 'auto',
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

    local versions = { cm5 = 'cm5-v2', mcu = 'mcu-v0' }
    local image_ids = { cm5 = 'cm5-release-2', mcu = 'mcu-image-0' }
    local sha = { mcu = string.rep('0', 64) }
    local boot = { cm5 = 'cm5-boot-1', mcu = 'mcu-boot-1' }

    local device_opts = {
      image_ids = image_ids,
      payload_sha256 = sha,
      boot_id = boot,
      fail_stage_once = true,
      block_stage_until_released = true,
      commit_version = { mcu = 'mcu-v1' },
      commit_image_id = { mcu = 'mcu-image-1' },
      commit_sha = { mcu = string.rep('b', 64) },
      bump_boot_id = true,
    }

    bind_device_double(scope, bus:connect(), versions, device_opts)

    local us1 = start_update_scope(scope, bus)
    wait_service_running(caller)
    assert(wait_job_state(caller, 'failed', 1.0))

    us1:cancel('restart after failure')
    local ost, st = fibers.current_scope():try(us1:join_op())
    assert(ost == 'ok')
    assert(st == 'cancelled' or st == 'ok' or st == 'failed')

    local pre_restart_ids = {}
    for id in pairs(control.namespaces['update/jobs'] or {}) do
      pre_restart_ids[id] = true
    end

    device_opts.block_stage_until_released = false

    local us2 = start_update_scope(scope, bus)
    fibers.current_scope():finally(function() us2:cancel('shutdown') end)
    wait_service_running(caller)

    local retry_id
    assert(probe.wait_until(function()
      for id, job in pairs(control.namespaces['update/jobs'] or {}) do
        if not pre_restart_ids[id]
          and type(job) == 'table'
          and job.component == 'mcu'
          and job.state == 'succeeded' then
          retry_id = id
          return true
        end
      end
      return false
    end, { timeout = 1.5, interval = 0.01 }))

    assert(probe.wait_until(function()
      local rec = ((control.namespaces['update/state/bundled'] or {}).mcu)
      return type(rec) == 'table'
        and rec.follow_mode == 'auto'
        and rec.sync_state == 'satisfied'
        and rec.last_attempt_job_id == retry_id
    end, { timeout = 1.5, interval = 0.01 }))
  end, { timeout = 5.0 })
end


function T.bundled_reconcile_caches_probe_by_release_and_source()
  local calls = 0
  local bundled = require 'services.update.bundled_reconcile'
  local inst = bundled.new({
    observer = {
      component_state_for = function(_, component)
        if component == 'cm5' then
          return { software = { image_id = 'cm5-release-1' } }
        end
      end,
    },
    artifacts = {
      resolve_job_artifact = function(_, payload)
        calls = calls + 1
        return 'art-' .. tostring(calls), {
          mcu_image = {
            build = { version = 'mcu-v1', build_id = 'b1', image_id = 'img-1' },
            payload = { sha256 = string.rep('a', 64) },
          },
        }, nil
      end,
      delete = function() return true end,
    },
  }, {}, { get = function() return nil end, put = function() return true end })

  local desired1, err1 = inst:probe_desired('mcu', { source = { kind = 'bundled', path = '/rom/mcu.dcmcu' } }, 'cm5-release-1')
  assert(err1 == nil)
  assert(type(desired1) == 'table' and desired1.image_id == 'img-1')
  local desired2, err2 = inst:probe_desired('mcu', { source = { kind = 'bundled', path = '/rom/mcu.dcmcu' } }, 'cm5-release-1')
  assert(err2 == nil)
  assert(type(desired2) == 'table' and desired2.image_id == 'img-1')
  assert(calls == 1)

  local desired3, err3 = inst:probe_desired('mcu', { source = { kind = 'bundled', path = '/rom/mcu.dcmcu' } }, 'cm5-release-2')
  assert(err3 == nil)
  assert(type(desired3) == 'table' and desired3.image_id == 'img-1')
  assert(calls == 2)
end

return T
