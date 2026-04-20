local cjson = require 'cjson.safe'

local T = {}

local function read_file(path)
  local f = assert(io.open(path, 'rb'))
  local s = assert(f:read('*a'))
  f:close()
  return s
end

function T.bigbox_v1_cm_2_profile_activates_fabric_device_update_and_not_mcu_bridge()
  local chunk = assert(loadfile('../src/devices/bigbox-v1-cm-2.lua'))
  local rec = assert(chunk())
  assert(type(rec) == 'table' and type(rec.services) == 'table')

  local seen = {}
  for i = 1, #rec.services do seen[rec.services[i]] = true end

  assert(seen.fabric == true)
  assert(seen.device == true)
  assert(seen.update == true)
  assert(seen.mcu_bridge ~= true)
end

function T.bigbox_v1_cm_2_config_defines_fabric_device_and_mcu_only_update_backend()
  local cfg = assert(cjson.decode(read_file('../src/configs/bigbox-v1-cm-2.json')))
  assert(type(cfg) == 'table')

  assert(type(cfg.fabric) == 'table')
  assert(type(cfg.fabric.links) == 'table')
  local link = cfg.fabric.links['cm5-uart-mcu']
  assert(type(link) == 'table')
  assert(link.member_class == 'mcu')
  assert(link.link_class == 'member_uart')
  assert(type(link.import_rules) == 'table' and #link.import_rules >= 1)
  assert(type(link.outbound_call_rules) == 'table' and #link.outbound_call_rules >= 1)

  assert(type(cfg.device) == 'table')
  assert(cfg.device.schema == 'devicecode.config/device/1')
  assert(type(cfg.device.components) == 'table')
  local mcu = cfg.device.components.mcu
  assert(type(mcu) == 'table')
  assert(mcu.member_class == 'mcu')
  assert(mcu.link_class == 'member_uart')
  assert(type(mcu.status_topic) == 'table')
  assert(type(mcu.get_topic) == 'table')
  assert(type(mcu.actions) == 'table')
  assert(type(mcu.actions.prepare_update) == 'table')
  assert(type(mcu.actions.commit_update) == 'table')

  assert(type(cfg.update) == 'table')
  assert(cfg.update.schema == 'devicecode.config/update/1')
  assert(type(cfg.update.components) == 'table')
  assert(type(cfg.update.components.mcu) == 'table')
  assert(cfg.update.components.mcu.backend == 'mcu_component')
  assert(type(cfg.update.components.mcu.transfer) == 'table')
  assert(cfg.update.components.mcu.transfer.link_id == 'cm5-uart-mcu')
  assert(type(cfg.update.components.mcu.transfer.receiver) == 'table')
  assert(cfg.update.components.cm5 == nil)

  assert(cfg.bridge == nil)
end

return T
