local component_mcu = require 'services.device.component_mcu'

local T = {}

function T.component_mcu_composes_split_facts()
  local out = component_mcu.compose({
    software = { version = 'mcu-v1', boot_id = 'boot-1' },
    updater = { state = 'running' },
    health = { state = 'ok' },
  }, {})

  assert(type(out) == 'table')
  assert(type(out.software) == 'table' and out.software.version == 'mcu-v1')
  assert(out.software.boot_id == 'boot-1')
  assert(type(out.updater) == 'table' and out.updater.state == 'running')
  assert(out.health == 'ok')
  assert(type(out.raw) == 'table')
  assert(type(out.raw.software) == 'table')
  assert(type(out.raw.updater) == 'table')
  assert(type(out.raw.health) == 'table')
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
    charger_alert = {
      kind = 'vin_lo',
      severity = 'warn',
      source = 'ltc4015',
      state_bits = 1,
      status_bits = 2,
      system_bits = 4,
    },
  })

  assert(type(out.software) == 'table' and out.software.version == 'mcu-v2')
  assert(type(out.updater) == 'table' and out.updater.state == 'running')
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

function T.component_mcu_composes_partial_fact_sets()
  local out = component_mcu.compose({
    updater = { state = 'running' },
  }, {})

  assert(type(out.updater) == 'table' and out.updater.state == 'running')
  assert(type(out.software) == 'table' and out.software.version == nil)
  assert(type(out.power) == 'table')
  assert(type(out.environment) == 'table')
  assert(type(out.runtime) == 'table')
  assert(type(out.alerts) == 'table')
end

function T.component_mcu_composes_empty_input()
  local out = component_mcu.compose({}, {})

  assert(type(out.software) == 'table' and out.software.version == nil)
  assert(type(out.updater) == 'table' and out.updater.state == nil)
  assert(type(out.power) == 'table')
  assert(type(out.environment) == 'table')
  assert(type(out.runtime) == 'table')
  assert(type(out.alerts) == 'table')
end

return T
