local component_host = require "services.device.component_host"

local T = {}

function T.component_host_composes_split_facts()
  local out = component_host.compose({
    software = { version = 'cm5-v1', boot_id = 'cm5-boot-1', hw_revision = 'A' },
    updater = { state = 'running', expected_version = nil },
    health = { state = 'ok' },
  }, {
    software = { seen = true },
    updater = { seen = true },
    health = { seen = true },
  })

  assert(out.available == true)
  assert(out.ready == true)
  assert(type(out.software) == 'table' and out.software.version == 'cm5-v1')
  assert(type(out.updater) == 'table' and out.updater.state == 'running')
  assert(out.health == 'ok')
  assert(type(out.source) == 'table' and out.source.kind == 'host')
end

return T
