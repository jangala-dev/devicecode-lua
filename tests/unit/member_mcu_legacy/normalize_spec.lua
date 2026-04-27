local normalize = require 'services.member_mcu_legacy.normalize'

local T = {}

function T.legacy_samples_normalise_to_canonical_member_facts()
  local facts = normalize.to_member_facts({
    ['power/battery/internal/vbat'] = 2412,
    ['power/battery/internal/ibat'] = 7,
    ['power/battery/internal/bsr'] = 42,
    ['power/temperature/internal'] = 19800,
    ['power/charger/internal/vin'] = 24317,
    ['power/charger/internal/vsys'] = 24233,
    ['power/charger/internal/iin'] = 658,
    ['power/charger/internal/system/ok_to_charge'] = true,
    ['power/charger/internal/status/cc_phase'] = true,
    ['power/charger/internal/state/bat_missing'] = true,
    ['env/temperature/core'] = 1910,
    ['env/humidity/core'] = 4690,
    ['sys/mem/alloc'] = 85680,
  })

  assert(type(facts) == 'table')
  assert(facts.power_battery.pack_mV == 2412)
  assert(facts.power_battery.ibat_mA == 7)
  assert(facts.power_battery.temp_mC == 198000)
  assert(facts.power_charger.vin_mV == 24317)
  assert(facts.power_charger.system.ok_to_charge == true)
  assert(facts.power_charger.status.const_current == true)
  assert(facts.power_charger.state.bat_missing_fault == true)
  assert(facts.environment_temperature.deci_c == 191)
  assert(facts.environment_humidity.rh_x100 == 4690)
  assert(facts.runtime_memory.alloc_bytes == 85680)
  assert(facts.updater.state == 'unavailable')
end

return T
