local component_mcu = require 'services.device.component_mcu'

local T = {}

function T.component_mcu_normalizes_plain_status()
  local out = component_mcu.normalize_status({
    version = 'mcu-v1',
    boot_id = 'boot-1',
    state = 'running',
    source = { kind = 'member' },
  })
  assert(out.available == true)
  assert(out.ready == true)
  assert(out.incarnation == 'boot-1')
  assert(type(out.software) == 'table' and out.software.version == 'mcu-v1')
  assert(type(out.updater) == 'table' and out.updater.state == 'running')
  assert(type(out.source) == 'table' and out.source.kind == 'member')
end

function T.component_mcu_normalizes_canonical_status()
  local out = component_mcu.normalize_status({
    available = true,
    ready = false,
    incarnation = 'inc-2',
    software = { version = 'mcu-v2' },
    updater = { state = 'idle' },
    capabilities = { update = true },
    source = { kind = 'member' },
  })
  assert(out.available == true)
  assert(out.ready == false)
  assert(out.incarnation == 'inc-2')
  assert(out.software.version == 'mcu-v2')
  assert(out.updater.state == 'idle')
  assert(out.capabilities.update == true)
end

return T
