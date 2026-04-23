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
  assert(joined(topics.member_event('mcu', 'power', 'charger', 'alert')) == 'event/member/mcu/power/charger/alert')
end

function T.mcu_schema_defines_fixed_alert_kind_set()
  assert(mcu.alert_kinds.vin_lo == true)
  assert(mcu.alert_kinds.cv_phase == true)
  assert(mcu.alert_kinds.not_a_real_alert == nil)
end

return T
