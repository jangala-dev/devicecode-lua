local contract = require 'services.update.backend_contract'

local T = {}

local function valid_backend()
  return {
    prepare = function() end,
    stage = function() end,
    commit = function() end,
    evaluate = function() end,
  }
end

function T.backend_contract_accepts_minimal_valid_backend()
  local backend, err = contract.validate('test', valid_backend())
  assert(err == nil)
  assert(type(backend) == 'table')
end

function T.backend_contract_rejects_missing_methods()
  local b = valid_backend()
  b.stage = nil
  local backend, err = contract.validate('bad', b)
  assert(backend == nil)
  assert(tostring(err):match('stage'))
end

function T.backend_contract_normalises_absent_observer_specs()
  local specs, err = contract.observe_specs('test', valid_backend(), {})
  assert(err == nil)
  assert(type(specs) == 'table')
  assert(#specs == 0)
end

return T
