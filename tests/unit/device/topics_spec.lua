local topics = require 'services.device.topics'
local mcu = require 'services.device.schemas.mcu'

local T = {}

local function joined(t)
  return table.concat(t, '/')
end

function T.device_topics_build_canonical_component_paths()
  assert(joined(topics.component('mcu')) == 'state/device/component/mcu')
  assert(joined(topics.raw_member_state('mcu', 'power', 'charger')) == 'raw/member/mcu/state/power/charger')
  assert(joined(topics.raw_member_state('mcu', 'power', 'charger', 'config')) == 'raw/member/mcu/state/power/charger/config')
  assert(joined(topics.raw_member_cap_event('mcu', 'telemetry', 'main', 'power', 'charger', 'alert')) == 'raw/member/mcu/cap/telemetry/main/event/power/charger/alert')
end

function T.mcu_schema_defines_fixed_alert_kind_set()
  assert(mcu.alert_kinds.vin_lo == true)
  assert(mcu.alert_kinds.cv_phase == true)
  assert(mcu.alert_kinds.not_a_real_alert == nil)
end

function T.mcu_schema_builds_full_member_fact_topics()
  local facts = mcu.member_fact_topics('mcu')
  assert(joined(facts.power_battery) == 'raw/member/mcu/state/power/battery')
  assert(joined(facts.power_charger) == 'raw/member/mcu/state/power/charger')
  assert(joined(facts.power_charger_config) == 'raw/member/mcu/state/power/charger/config')
  assert(joined(facts.environment_temperature) == 'raw/member/mcu/state/environment/temperature')
  assert(joined(facts.environment_humidity) == 'raw/member/mcu/state/environment/humidity')
  assert(joined(facts.runtime_memory) == 'raw/member/mcu/state/runtime/memory')
end

return T
