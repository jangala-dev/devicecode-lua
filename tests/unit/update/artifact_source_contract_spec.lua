local contract = require 'services.update.artifact_source_contract'
local sources = require 'services.update.artifact_sources'

local T = {}

function T.artifact_source_contract_rejects_missing_resolve()
  local ok, err = contract.validate('bad', {})
  assert(ok == nil)
  assert(tostring(err):match('resolve'))
end

function T.artifact_sources_can_register_custom_resolver()
  local called = false
  local ok, err = sources.register('custom_test', {
    resolve = function(_artifacts, _component, artifact)
      called = true
      return artifact.ref, { size = 1 }, true, nil
    end,
  })
  assert(ok == true and err == nil)
  local ref, meta, cleanup_on_failure, rerr = sources.resolve({}, 'mcu', { kind = 'custom_test', ref = 'x' }, nil)
  assert(rerr == nil)
  assert(ref == 'x')
  assert(meta.size == 1)
  assert(cleanup_on_failure == true)
  assert(called == true)
end

return T
