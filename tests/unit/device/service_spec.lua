local busmod    = require 'bus'
local runfibers = require 'tests.support.run_fibers'
local probe     = require 'tests.support.bus_probe'
local test_diag = require 'tests.support.test_diag'
local model = require 'services.device.model'
local device    = require 'services.device'
local safe      = require 'coxpcall'

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

function T.device_service_proxies_default_cm5_status_and_update_calls()
  runfibers.run(function(scope)
    local bus = busmod.new()
    local caller = bus:connect()
    local provider = bus:connect()
    local diag = test_diag.for_stack(scope, bus, { device = true, max_records = 240 })
    test_diag.add_subsystem(diag, 'device', {
      service_fn = test_diag.retained_fn(caller, { 'svc', 'device', 'status' }),
      summary_fn = test_diag.retained_fn(caller, { 'state', 'device' }),
      cm5_fn = test_diag.retained_fn(caller, { 'state', 'device', 'component', 'cm5' }),
    })

    provider:retain({ 'cap', 'updater', 'cm5', 'state', 'software' }, {
      version = 'cm5-v1',
      boot_id = 'cm5-boot-1',
      image_id = 'cm5-v1',
    })
    provider:retain({ 'cap', 'updater', 'cm5', 'state', 'updater' }, {
      state = 'running',
      staged = false,
      artifact_ref = nil,
      expected_version = nil,
      last_error = nil,
    })
    provider:retain({ 'cap', 'updater', 'cm5', 'state', 'health' }, {
      state = 'ok',
      reason = nil,
    })

    local prepare_ep = provider:bind({ 'cap', 'updater', 'cm5', 'rpc', 'prepare' }, { queue_len = 16 })
    local stage_ep = provider:bind({ 'cap', 'updater', 'cm5', 'rpc', 'stage' }, { queue_len = 16 })
    local commit_ep = provider:bind({ 'cap', 'updater', 'cm5', 'rpc', 'commit' }, { queue_len = 16 })

    bind_reply_loop(scope, prepare_ep, function(payload)
      return { ok = true, prepared = payload.component }
    end)
    bind_reply_loop(scope, stage_ep, function(payload)
      return { ok = true, staged = payload.artifact_ref, expected_version = payload.expected_version, artifact_retention = 'keep' }
    end)
    bind_reply_loop(scope, commit_ep, function(payload)
      return { ok = true, started = true, mode = payload.component }
    end)

    local ok, err = scope:spawn(function()
      device.start(bus:connect(), { name = 'device', env = 'dev' })
    end)
    if not ok then diag:fail('failed to spawn device service: ' .. tostring(err)) end

    wait_service_running(caller, 'device')

    assert(probe.wait_until(function()
      local okp, payload = safe.pcall(function()
        return probe.wait_payload(caller, { 'state', 'device', 'component', 'cm5' }, { timeout = 0.02 })
      end)
      return okp
        and type(payload) == 'table'
        and payload.available == true
        and payload.ready == true
        and type(payload.software) == 'table'
        and payload.software.version == 'cm5-v1'
        and type(payload.updater) == 'table'
        and payload.updater.state == 'running'
    end, { timeout = 0.75, interval = 0.01 }))

    local status, serr = caller:call({ 'cmd', 'device', 'component', 'get' }, { component = 'cm5' }, { timeout = 0.5 })
    assert(serr == nil)
    assert(type(status) == 'table')
    assert(status.component == 'cm5')
    assert(type(status.software) == 'table')
    assert(status.software.version == 'cm5-v1')
    assert(type(status.updater) == 'table')
    assert(status.updater.state == 'running')
    assert(status.actions.stage_update == true)

    local staged, terr = caller:call({ 'cmd', 'device', 'component', 'do' }, {
      component = 'cm5',
      action = 'stage_update',
      args = { artifact_ref = 'art-1', expected_version = '1.2.3' },
    }, { timeout = 0.5 })
    assert(terr == nil)
    assert(staged.ok == true)
    assert(staged.staged == 'art-1')
    assert(staged.expected_version == '1.2.3')
  end, { timeout = 2.0 })
end

function T.device_service_merges_configured_components_and_tracks_split_fact_topics()
  runfibers.run(function(scope)
    local bus = busmod.new()
    local caller = bus:connect()
    local seed = bus:connect()
    local provider = bus:connect()
    local diag = test_diag.for_stack(scope, bus, { device = true, config = true, max_records = 240 })
    test_diag.add_subsystem(diag, 'device', {
      service_fn = test_diag.retained_fn(caller, { 'svc', 'device', 'status' }),
      summary_fn = test_diag.retained_fn(caller, { 'state', 'device' }),
      mcu_fn = test_diag.retained_fn(caller, { 'state', 'device', 'component', 'mcu' }),
    })

    seed:retain({ 'cfg', 'device' }, {
      schema = 'devicecode.config/device/1',
      components = {
        mcu = {
          class = 'member',
          subtype = 'mcu',
          facts = {
            software = { 'state', 'member', 'mcu', 'software' },
            updater = { 'state', 'member', 'mcu', 'updater' },
            health = { 'state', 'member', 'mcu', 'health' },
          },
          actions = {
            prepare_update = { 'cap', 'updater', 'mcu', 'rpc', 'prepare' },
          },
        },
      },
    })

    local prepare_ep = provider:bind({ 'cap', 'updater', 'mcu', 'rpc', 'prepare' }, { queue_len = 16 })
    bind_reply_loop(scope, prepare_ep, function(payload)
      return { ok = true, prepared = payload.target or 'mcu' }
    end)

    provider:retain({ 'state', 'member', 'mcu', 'software' }, {
      version = 'mcu-v2',
      boot_id = 'mcu-boot-7',
    })
    provider:retain({ 'state', 'member', 'mcu', 'updater' }, {
      state = 'running',
    })
    provider:retain({ 'state', 'member', 'mcu', 'health' }, {
      state = 'ok',
    })

    local ok, err = scope:spawn(function()
      device.start(bus:connect(), { name = 'device', env = 'dev' })
    end)
    if not ok then diag:fail('failed to spawn device service: ' .. tostring(err)) end

    wait_service_running(caller, 'device')

    assert(probe.wait_until(function()
      local okp, payload = safe.pcall(function()
        return probe.wait_payload(caller, { 'state', 'device', 'component', 'mcu' }, { timeout = 0.02 })
      end)
      return okp
        and type(payload) == 'table'
        and payload.kind == 'device.component'
        and payload.available == true
        and payload.ready == true
        and type(payload.software) == 'table'
        and payload.software.version == 'mcu-v2'
        and payload.software.boot_id == 'mcu-boot-7'
        and type(payload.updater) == 'table'
        and payload.updater.state == 'running'
        and payload.member_class == 'mcu'
        and payload.link_class == nil
        and type(payload.source) == 'table' and payload.source.member_class == 'mcu'
        and type(payload.source.facts) == 'table'
        and type(payload.source.facts.software) == 'table'
        and payload.actions.stage_update == nil
    end, { timeout = 0.75, interval = 0.01 }))

    local reply, rerr = caller:call({ 'cmd', 'device', 'component', 'do' }, {
      component = 'mcu',
      action = 'prepare_update',
      args = { target = 'mcu' },
    }, { timeout = 0.5 })
    assert(rerr == nil)
    assert(reply.ok == true)
  end, { timeout = 2.0 })
end

function T.device_service_rejects_components_without_observations()
  local ok, err = pcall(function()
    model.merge_components({
      schema = 'devicecode.config/device/1',
      components = {
        broken = {
          class = 'member',
          subtype = 'mcu',
          actions = {
            prepare_update = { 'cmd', 'x' },
          },
        },
      },
    }, 'devicecode.config/device/1')
  end)
  assert(ok == false)
  assert(tostring(err):match('observation') ~= nil or tostring(err):match('fact') ~= nil)
end



function T.device_service_republishes_component_events_and_records_last_event()
  runfibers.run(function(scope)
    local bus = busmod.new()
    local caller = bus:connect()
    local seed = bus:connect()
    local provider = bus:connect()

    seed:retain({ 'cfg', 'device' }, {
      schema = 'devicecode.config/device/1',
      components = {
        mcu = {
          class = 'member',
          subtype = 'mcu',
          facts = {
            software = { 'state', 'member', 'mcu', 'software' },
            updater = { 'state', 'member', 'mcu', 'updater' },
          },
          events = {
            charger_alert = { 'event', 'member', 'mcu', 'power', 'charger', 'alert' },
          },
        },
      },
    })

    provider:retain({ 'state', 'member', 'mcu', 'software' }, { version = 'mcu-v2' })
    provider:retain({ 'state', 'member', 'mcu', 'updater' }, { state = 'running' })

    local sub = caller:subscribe({ 'event', 'device', 'component', 'mcu', 'charger_alert' }, { queue_len = 4 })

    local ok, err = scope:spawn(function()
      device.start(bus:connect(), { name = 'device', env = 'dev' })
    end)
    assert(ok, tostring(err))
    wait_service_running(caller, 'device')

    provider:publish({ 'event', 'member', 'mcu', 'power', 'charger', 'alert' }, {
      kind = 'vin_lo',
      severity = 'warn',
    })

    local ev, eerr = sub:recv()
    assert(eerr == nil)
    assert(type(ev) == 'table')
    assert(type(ev.payload) == 'table')
    assert(ev.payload.kind == 'vin_lo')

    assert(probe.wait_until(function()
      local okp, payload = safe.pcall(function()
        return probe.wait_payload(caller, { 'state', 'device', 'component', 'mcu' }, { timeout = 0.02 })
      end)
      return okp
        and type(payload) == 'table'
        and type(payload.events) == 'table'
        and type(payload.events.charger_alert) == 'table'
        and payload.events.charger_alert.kind == 'vin_lo'
    end, { timeout = 0.75, interval = 0.01 }))

    sub:unsubscribe()
  end, { timeout = 2.0 })
end

return T
