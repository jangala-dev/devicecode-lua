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
    return okp and type(payload) == 'table' and payload.state == 'running' and payload.ready == true
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

    provider:retain({ 'raw', 'host', 'updater', 'cap', 'updater', 'cm5', 'state', 'software' }, {
      version = 'cm5-v1',
      boot_id = 'cm5-boot-1',
      image_id = 'cm5-v1',
    })
    provider:retain({ 'raw', 'host', 'updater', 'cap', 'updater', 'cm5', 'state', 'updater' }, {
      state = 'running',
      staged = false,
      artifact_ref = nil,
      expected_image_id = nil,
      last_error = nil,
    })
    provider:retain({ 'raw', 'host', 'updater', 'cap', 'updater', 'cm5', 'state', 'health' }, {
      state = 'ok',
      reason = nil,
    })

    local prepare_ep = provider:bind({ 'raw', 'host', 'updater', 'cap', 'updater', 'cm5', 'rpc', 'prepare' }, { queue_len = 16 })
    local stage_ep = provider:bind({ 'raw', 'host', 'updater', 'cap', 'updater', 'cm5', 'rpc', 'stage' }, { queue_len = 16 })
    local commit_ep = provider:bind({ 'raw', 'host', 'updater', 'cap', 'updater', 'cm5', 'rpc', 'commit' }, { queue_len = 16 })

    bind_reply_loop(scope, prepare_ep, function(payload)
      return { ok = true, prepared = payload.component }
    end)
    bind_reply_loop(scope, stage_ep, function(payload)
      return { ok = true, staged = payload.artifact_ref, expected_image_id = payload.expected_image_id, artifact_retention = 'keep' }
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

    local status, serr = caller:call({ 'cap', 'device', 'main', 'rpc', 'get-component' }, { component = 'cm5' }, { timeout = 0.5 })
    assert(serr == nil)
    assert(type(status) == 'table')
    assert(status.component == 'cm5')
    assert(type(status.software) == 'table')
    assert(status.software.version == 'cm5-v1')
    assert(type(status.updater) == 'table')
    assert(status.updater.state == 'running')
    assert(status.actions['stage-update'] == true)

    local staged, terr = caller:call({ 'cap', 'component', 'cm5', 'rpc', 'stage-update' }, { artifact_ref = 'art-1', expected_image_id = '1.2.3' }, { timeout = 0.5 })
    assert(terr == nil)
    assert(staged.ok == true)
    assert(staged.staged == 'art-1')
    assert(staged.expected_image_id == '1.2.3')
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
          required_facts = { 'software', 'updater' },
          facts = {
            software = { 'raw', 'member', 'mcu', 'state', 'software' },
            updater = { 'raw', 'member', 'mcu', 'state', 'updater' },
            health = { 'raw', 'member', 'mcu', 'state', 'health' },
            power_battery = { 'raw', 'member', 'mcu', 'state', 'power', 'battery' },
            power_charger = { 'raw', 'member', 'mcu', 'state', 'power', 'charger' },
            power_charger_config = { 'raw', 'member', 'mcu', 'state', 'power', 'charger', 'config' },
            environment_temperature = { 'raw', 'member', 'mcu', 'state', 'environment', 'temperature' },
            environment_humidity = { 'raw', 'member', 'mcu', 'state', 'environment', 'humidity' },
            runtime_memory = { 'raw', 'member', 'mcu', 'state', 'runtime', 'memory' },
          },
          actions = {
            ['prepare-update'] = { 'raw', 'member', 'mcu', 'cap', 'updater', 'main', 'rpc', 'prepare' },
          },
        },
      },
    })

    local prepare_ep = provider:bind({ 'raw', 'member', 'mcu', 'cap', 'updater', 'main', 'rpc', 'prepare' }, { queue_len = 16 })
    bind_reply_loop(scope, prepare_ep, function(payload)
      return { ok = true, prepared = payload.target or 'mcu' }
    end)

    provider:retain({ 'raw', 'member', 'mcu', 'state', 'software' }, {
      version = 'mcu-v2',
      boot_id = 'mcu-boot-7',
    })
    provider:retain({ 'raw', 'member', 'mcu', 'state', 'updater' }, {
      state = 'running',
    })
    provider:retain({ 'raw', 'member', 'mcu', 'state', 'health' }, {
      state = 'ok',
    })

    provider:retain({ 'raw', 'member', 'mcu', 'state', 'power', 'battery' }, {
      pack_mV = 2412,
      per_cell_mV = 1206,
      ibat_mA = 7,
      temp_mC = 198000,
      bsr_uohm_per_cell = 42,
    })
    provider:retain({ 'raw', 'member', 'mcu', 'state', 'power', 'charger' }, {
      vin_mV = 24317,
      vsys_mV = 24233,
      iin_mA = 658,
      state_bits = 1,
      status_bits = 2,
      system_bits = 4,
      state = { bat_missing_fault = true },
      status = { const_current = true },
      system = { ok_to_charge = true },
    })
    provider:retain({ 'raw', 'member', 'mcu', 'state', 'power', 'charger', 'config' }, {
      schema = 1,
      source = 'ltc4015',
      thresholds = {
        vin_lo_mV = 9000,
        vin_hi_mV = 32000,
        bsr_high_uohm_per_cell = 50000,
      },
      alert_mask_bits = 16383,
      alert_mask = {
        vin_lo = true,
        cv_phase = true,
      },
    })
    provider:retain({ 'raw', 'member', 'mcu', 'state', 'environment', 'temperature' }, {
      deci_c = 191,
    })
    provider:retain({ 'raw', 'member', 'mcu', 'state', 'environment', 'humidity' }, {
      rh_x100 = 4690,
    })
    provider:retain({ 'raw', 'member', 'mcu', 'state', 'runtime', 'memory' }, {
      alloc_bytes = 85680,
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
        and type(payload.source) == 'table'
        and payload.source.member_class == 'mcu'
        and payload.actions['stage-update'] == nil
        and type(payload.power) == 'table'
        and type(payload.power.battery) == 'table'
        and payload.power.battery.pack_mV == 2412
        and type(payload.power.charger) == 'table'
        and payload.power.charger.vin_mV == 24317
        and payload.power.charger.state.bat_missing_fault == true
        and payload.power.charger.charger_config == nil
        and type(payload.power.charger_config) == 'table'
        and payload.power.charger_config.thresholds.vin_lo_mV == 9000
        and type(payload.environment) == 'table'
        and payload.environment.temperature.deci_c == 191
        and payload.environment.humidity.rh_x100 == 4690
        and type(payload.runtime) == 'table'
        and payload.runtime.memory.alloc_bytes == 85680
    end, { timeout = 0.75, interval = 0.01 }))

    local reply, rerr = caller:call({ 'cap', 'component', 'mcu', 'rpc', 'prepare-update' }, { target = 'mcu' }, { timeout = 0.5 })
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
            ['prepare-update'] = { 'cmd', 'x' },
          },
        },
      },
    }, 'devicecode.config/device/1')
  end)
  assert(ok == false)
  assert(tostring(err):match('observation') ~= nil or tostring(err):match('fact') ~= nil)
end

return T
