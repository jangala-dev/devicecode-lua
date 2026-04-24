local component_mcu = require 'services.device.component_mcu'

local T = {}

function T.component_mcu_composes_split_facts()
  local out = component_mcu.compose({
    software = { version = 'mcu-v1', boot_id = 'boot-1' },
    updater = { state = 'running' },
    health = { state = 'ok' },
  }, {
    software = { seen = true },
    updater = { seen = true },
    health = { seen = true },
  })
  assert(out.available == true)
  assert(out.ready == true)
  assert(type(out.software) == 'table' and out.software.version == 'mcu-v1')
  assert(type(out.updater) == 'table' and out.updater.state == 'running')
  assert(out.health == 'ok')
  assert(type(out.source) == 'table' and out.source.kind == 'member')
end

function T.component_mcu_composes_pmu_telemetry_config_and_last_alert()
  local out = component_mcu.compose({
    software = { version = 'mcu-v2', boot_id = 'boot-2' },
    updater = { state = 'running' },
    power_battery = {
      pack_mV = 2412,
      per_cell_mV = 1206,
      ibat_mA = 7,
      temp_mC = 198000,
      bsr_uohm_per_cell = 42,
    },
    power_charger = {
      vin_mV = 24317,
      vsys_mV = 24233,
      iin_mA = 658,
      state_bits = 1,
      status_bits = 2,
      system_bits = 4,
      state = { bat_missing_fault = true },
      status = { const_current = true },
      system = { ok_to_charge = true },
    },
    power_charger_config = {
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
    },
    environment_temperature = { deci_c = 191 },
    environment_humidity = { rh_x100 = 4690 },
    runtime_memory = { alloc_bytes = 85680 },
  }, {
    software = { seen = true },
    updater = { seen = true },
    power_battery = { seen = true },
    power_charger = { seen = true },
    power_charger_config = { seen = true },
    environment_temperature = { seen = true },
    environment_humidity = { seen = true },
    runtime_memory = { seen = true },
  }, {
    charger_alert = {
      kind = 'vin_lo',
      severity = 'warn',
      source = 'ltc4015',
      state_bits = 1,
      status_bits = 2,
      system_bits = 4,
    },
  }, {
    charger_alert = { seen = true, count = 1 },
  })

  assert(out.available == true)
  assert(out.ready == true)
  assert(out.power.battery.pack_mV == 2412)
  assert(out.power.battery.temp_mC == 198000)
  assert(out.power.charger.vin_mV == 24317)
  assert(out.power.charger.state.bat_missing_fault == true)
  assert(out.power.charger.status.const_current == true)
  assert(out.power.charger.system.ok_to_charge == true)
  assert(out.power.charger_config.thresholds.vin_lo_mV == 9000)
  assert(out.power.charger_config.alert_mask.vin_lo == true)
  assert(out.environment.temperature.deci_c == 191)
  assert(out.environment.humidity.rh_x100 == 4690)
  assert(out.runtime.memory.alloc_bytes == 85680)
  assert(out.alerts.charger_alert.kind == 'vin_lo')
  assert(out.alerts.charger_alert.known == true)
end

function T.component_mcu_marks_partial_fact_sets_not_ready()
  local out = component_mcu.compose({
    updater = { state = 'running' },
  }, {
    updater = { seen = true },
  })
  assert(out.available == true)
  assert(out.ready == false)
  assert(type(out.updater) == 'table' and out.updater.state == 'running')
  assert(type(out.software) == 'table' and out.software.version == nil)
end

function T.component_mcu_marks_no_facts_unavailable()
  local out = component_mcu.compose({})
  assert(out.available == false)
  assert(out.ready == false)
  assert(type(out.software) == 'table' and out.software.version == nil)
  assert(type(out.updater) == 'table' and out.updater.state == nil)
end

return T
