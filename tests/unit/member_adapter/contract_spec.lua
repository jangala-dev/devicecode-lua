local contract = require 'services.member_adapter.contract'
local runtime = require 'services.member_adapter.runtime'

local T = {}

function T.member_adapter_contract_accepts_basic_spec()
  local spec, err = contract.validate_spec('legacy_mcu', {
    member = 'mcu',
    facts = { software = { 'software' } },
    events = { charger_alert = { 'power', 'charger', 'alert' } },
  })
  assert(err == nil)
  assert(spec.member == 'mcu')
  assert(type(spec.facts.software) == 'table')
end

function T.member_adapter_runtime_builds_member_topics()
  local published = {}
  local conn = {
    retain = function(_, topic, payload) published[#published + 1] = { kind = 'retain', topic = topic, payload = payload } end,
    publish = function(_, topic, payload) published[#published + 1] = { kind = 'publish', topic = topic, payload = payload } end,
  }
  local rt = runtime.new(conn, 'mcu')
  rt:retain_state({ 'software' }, { version = 'v1' })
  rt:publish_event({ 'power', 'charger', 'alert' }, { kind = 'vin_lo' })
  assert(table.concat(published[1].topic, '/') == 'raw/member/mcu/state/software')
  assert(table.concat(published[2].topic, '/') == 'raw/member/mcu/cap/telemetry/main/event/power/charger/alert')
end

return T
