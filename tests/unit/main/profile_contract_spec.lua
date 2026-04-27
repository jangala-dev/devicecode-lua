local contract = require 'devicecode.profile_contract'

local T = {}

function T.profile_contract_validates_bigbox_v1_cm_2_services()
  local profile = contract.load_profile('../src/devices/bigbox-v1-cm-2.lua')
  local seen, err = contract.validate_profile_services(profile, {
    required = { 'fabric', 'device', 'update' },
    forbidden = { 'mcu_bridge' },
  })
  assert(err == nil)
  assert(seen.fabric == true and seen.device == true and seen.update == true)
end

function T.profile_contract_loads_bigbox_v1_cm_2_config_and_paths()
  local cfg = contract.load_config_json('../src/configs/bigbox-v1-cm-2.json')
  local link, err = contract.require_path(cfg, { 'fabric', 'links', 'cm5-uart-mcu' })
  assert(err == nil)
  assert(type(link) == 'table')
  local comp, err2 = contract.require_path(cfg, { 'device', 'components', 'mcu' })
  assert(err2 == nil)
  assert(type(comp) == 'table')
  local upd, err3 = contract.require_path(cfg, { 'update', 'components', 'mcu' })
  assert(err3 == nil)
  assert(type(upd) == 'table')
end

return T
