local busmod    = require 'bus'
local runfibers = require 'tests.support.run_fibers'
local probe     = require 'tests.support.bus_probe'
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

    local status_ep = provider:bind({ 'cap', 'updater', 'cm5', 'rpc', 'status' }, { queue_len = 16 })
    local prepare_ep = provider:bind({ 'cap', 'updater', 'cm5', 'rpc', 'prepare' }, { queue_len = 16 })
    local stage_ep = provider:bind({ 'cap', 'updater', 'cm5', 'rpc', 'stage' }, { queue_len = 16 })
    local commit_ep = provider:bind({ 'cap', 'updater', 'cm5', 'rpc', 'commit' }, { queue_len = 16 })

    bind_reply_loop(scope, status_ep, function()
      return { version = 'cm5-v1', state = 'running' }
    end)
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
    assert(ok, tostring(err))

    wait_service_running(caller, 'device')

    local status, serr = caller:call({ 'cmd', 'device', 'component', 'get' }, { component = 'cm5' }, { timeout = 0.5 })
    assert(serr == nil)
    assert(status.ok == true)
    assert(type(status.component) == 'table')
    assert(status.component.component == 'cm5')
    assert(type(status.component.status) == 'table')
    assert(status.component.status.version == 'cm5-v1')
    assert(status.component.actions.stage_update == true)

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

function T.device_service_merges_configured_components_and_tracks_status_topics()
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
          status_topic = { 'cap', 'updater', 'mcu', 'state', 'status' },
          get_topic = { 'cap', 'updater', 'mcu', 'rpc', 'status' },
          actions = {
            stage_update = { 'cap', 'updater', 'mcu', 'rpc', 'stage' },
          },
        },
      },
    })

    local status_ep = provider:bind({ 'cap', 'updater', 'mcu', 'rpc', 'status' }, { queue_len = 16 })
    local stage_ep = provider:bind({ 'cap', 'updater', 'mcu', 'rpc', 'stage' }, { queue_len = 16 })
    bind_reply_loop(scope, status_ep, function()
      return { version = 'mcu-v2', state = 'running', incarnation = 7 }
    end)
    bind_reply_loop(scope, stage_ep, function(payload)
      return { ok = true, staged = payload.artifact_ref, artifact_retention = 'release' }
    end)

    local ok, err = scope:spawn(function()
      device.start(bus:connect(), { name = 'device', env = 'dev' })
    end)
    assert(ok, tostring(err))

    wait_service_running(caller, 'device')

    provider:publish({ 'cap', 'updater', 'mcu', 'state', 'status' }, {
      version = 'mcu-v2',
      state = 'running',
      incarnation = 7,
    })

    assert(probe.wait_until(function()
      local okp, payload = safe.pcall(function()
        return probe.wait_payload(caller, { 'state', 'device', 'component', 'mcu' }, { timeout = 0.02 })
      end)
      return okp
        and type(payload) == 'table'
        and payload.kind == 'device.component'
        and type(payload.status) == 'table'
        and payload.status.version == 'mcu-v2'
        and payload.incarnation == 7
        and payload.member_class == 'mcu'
        and payload.link_class == nil
        and type(payload.source) == 'table' and payload.source.member_class == 'mcu'
        and payload.actions.stage_update == true
    end, { timeout = 0.75, interval = 0.01 }))

    local reply, rerr = caller:call({ 'cmd', 'device', 'component', 'do' }, {
      component = 'mcu',
      action = 'stage_update',
      args = { artifact_ref = 'art-9' },
    }, { timeout = 0.5 })
    assert(rerr == nil)
    assert(reply.ok == true)
    assert(reply.staged == 'art-9')
  end, { timeout = 2.0 })
end

return T
