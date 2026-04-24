local topics = require 'services.device.topics'
local mcu = require 'services.device.schemas.mcu'

local T = {}

local function joined(t)
  return table.concat(t, '/')
end

function T.device_topics_build_canonical_component_paths()
  assert(joined(topics.component('mcu')) == 'state/device/component/mcu')
  assert(joined(topics.component_event('mcu', 'charger_alert')) == 'event/device/component/mcu/charger_alert')
  assert(joined(topics.member_state('mcu', 'power', 'charger')) == 'state/member/mcu/power/charger')
  assert(joined(topics.member_state('mcu', 'power', 'charger', 'config')) == 'state/member/mcu/power/charger/config')
  assert(joined(topics.member_event('mcu', 'power', 'charger', 'alert')) == 'event/member/mcu/power/charger/alert')
end

function T.mcu_schema_defines_fixed_alert_kind_set()
  assert(mcu.alert_kinds.vin_lo == true)
  assert(mcu.alert_kinds.cv_phase == true)
  assert(mcu.alert_kinds.not_a_real_alert == nil)
end

function T.mcu_schema_builds_full_member_fact_topics()
  local facts = mcu.member_fact_topics('mcu')
  assert(joined(facts.power_battery) == 'state/member/mcu/power/battery')
  assert(joined(facts.power_charger) == 'state/member/mcu/power/charger')
  assert(joined(facts.power_charger_config) == 'state/member/mcu/power/charger/config')
  assert(joined(facts.environment_temperature) == 'state/member/mcu/environment/temperature')
  assert(joined(facts.environment_humidity) == 'state/member/mcu/environment/humidity')
  assert(joined(facts.runtime_memory) == 'state/member/mcu/runtime/memory')
end

return T
