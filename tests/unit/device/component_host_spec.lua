local component_host = require 'services.device.component_host'

local T = {}

function T.component_host_composes_split_facts()
  local out = component_host.compose({
    software = { version = 'cm5-v1', boot_id = 'cm5-boot-1', hw_revision = 'A' },
    updater = { state = 'running', expected_image_id = nil },
    health = { state = 'ok' },
  })

  assert(type(out) == 'table')
  assert(type(out.software) == 'table' and out.software.version == 'cm5-v1')
  assert(out.software.boot_id == 'cm5-boot-1')
  assert(out.software.hw_revision == 'A')
  assert(type(out.updater) == 'table' and out.updater.state == 'running')
  assert(out.health == 'ok')
  assert(type(out.raw) == 'table')
  assert(type(out.raw.software) == 'table')
  assert(type(out.raw.updater) == 'table')
  assert(type(out.raw.health) == 'table')
end

return T
