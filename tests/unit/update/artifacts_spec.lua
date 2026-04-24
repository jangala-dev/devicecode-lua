local artifacts_mod = require 'services.update.artifacts'

local T = {}

function T.artifacts_module_imports_path_with_component_policy()
  local called = {}
  local ctx = {
    state = {
      cfg = {
        artifacts = {
          default_policy = 'prefer_durable',
          policies = { mcu = 'transient_only' },
        },
      },
    },
    artifact_cap = {
      call_control = function(_, op, opts)
        called[#called + 1] = { op = op, opts = opts }
        if op == 'import_path' then
          return {
            ok = true,
            reason = {
              ref = function() return 'artifact:1' end,
              describe = function() return { size = 12, checksum = 'sha256:abc' } end,
            },
          }, nil
        end
        return nil, 'unexpected'
      end,
    },
  }
  local artifacts = artifacts_mod.new(ctx)
  local ref, meta, err = artifacts:import_path('/rom/mcu.bin', 'mcu', { build = 'x' })
  assert(err == nil)
  assert(ref == 'artifact:1')
  assert(type(meta) == 'table' and meta.size == 12)
  assert(called[1].op == 'import_path')
end

function T.inspect_mcu_artifact_requires_signature_cap_when_signature_is_needed()
  local ctx = { state = { cfg = {} } }
  local artifacts = artifacts_mod.new(ctx)
  local art = {
    open_source = function() return require('shared.blob_source').from_string('x') end,
  }
  local out, err = artifacts:inspect_mcu_artifact(art, { preflight = { require_signature = true } })
  assert(out == nil)
  assert(err == 'signature_verifier_unavailable')
end

return T
