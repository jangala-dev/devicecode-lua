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
