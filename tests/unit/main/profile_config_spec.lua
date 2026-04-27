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
  assert(type(mcu.facts) == 'table')
  assert(type(mcu.facts.software) == 'table')
  assert(type(mcu.facts.updater) == 'table')
  assert(type(mcu.facts.health) == 'table')
  assert(mcu.status_topic == nil)
  assert(mcu.get_topic == nil)
  assert(type(mcu.actions) == 'table')
  assert(type(mcu.actions['prepare-update']) == 'table')
  assert(type(mcu.actions['stage-update']) == 'table')
  assert(mcu.actions['stage-update'].kind == 'fabric_stage')
  assert(mcu.actions['stage-update'].link_id == 'cm5-uart-mcu')
  assert(type(mcu.actions['commit-update']) == 'table')

  assert(type(cfg.update) == 'table')
  assert(cfg.update.schema == 'devicecode.config/update/1')
  assert(type(cfg.update.components) == 'table')
  assert(type(cfg.update.components.mcu) == 'table')
  assert(cfg.update.components.mcu.backend == 'mcu_component')
  assert(cfg.update.components.mcu.transfer == nil)
  assert(type(cfg.update.bundled) == 'table')
  assert(type(cfg.update.bundled.components.mcu) == 'table')
  assert(cfg.update.bundled.components.mcu.enabled == true)
  assert(cfg.update.bundled.components.mcu.source.kind == 'bundled')
  assert(cfg.update.components.cm5 == nil)

  assert(cfg.bridge == nil)
end


function T.default_config_models_cm5_as_fact_backed_component()
  local cfg = assert(cjson.decode(read_file('../src/configs/config.json')))
  assert(type(cfg) == 'table')
  assert(type(cfg.device) == 'table')
  assert(type(cfg.device.data) == 'table')
  local cm5 = cfg.device.data.components.cm5
  assert(type(cm5) == 'table')
  assert(type(cm5.facts) == 'table')
  assert(type(cm5.facts.software) == 'table')
  assert(type(cm5.facts.updater) == 'table')
  assert(type(cm5.facts.health) == 'table')
  assert(cm5.status_topic == nil)
  assert(cm5.get_topic == nil)
end

return T
