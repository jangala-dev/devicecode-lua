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

function T.resolve_job_artifact_runs_injected_mcu_preflight_for_import_path()
  local called = {}
  local artifacts = artifacts_mod.new({
    state = { cfg = {} },
    artifact_cap = {
      call_control = function(_, op, _opts)
        called[#called + 1] = op
        if op == 'import_path' then
          return { ok = true, reason = {
            ref = function() return 'artifact:1' end,
            describe = function() return { size = 7, checksum = 'sha256:x' } end,
          } }, nil
        end
        if op == 'delete' then
          return { ok = true, reason = true }, nil
        end
        return nil, 'unexpected:' .. tostring(op)
      end,
    },
  })
  artifacts:set_preflighter('mcu', function(_self, ref, desc, artifact_spec)
    assert(ref == 'artifact:1')
    assert(type(desc) == 'table' and desc.size == 7)
    assert(type(artifact_spec) == 'table' and artifact_spec.kind == 'import_path')
    desc.mcu_image = { build = { version = 'mcu-v1', build_id = 'b1', image_id = 'img1' }, payload = { sha256 = string.rep('a', 64) } }
    return desc, nil
  end)

  local ref, desc, err = artifacts:resolve_job_artifact({
    component = 'mcu',
    artifact = { kind = 'import_path', path = '/tmp/mcu.bin' },
  })
  assert(err == nil)
  assert(ref == 'artifact:1')
  assert(type(desc.mcu_image) == 'table')
  assert(called[1] == 'import_path')
end

function T.resolve_job_artifact_does_not_delete_ref_when_preflight_fails()
  local deleted = false
  local artifacts = artifacts_mod.new({
    state = { cfg = {} },
    artifact_cap = {
      call_control = function(_, op, _opts)
        if op == 'open' then
          return { ok = true, reason = {
            describe = function() return { size = 7, checksum = 'sha256:x' } end,
            open_source = function() return require('shared.blob_source').from_string('x') end,
          } }, nil
        end
        if op == 'delete' then
          deleted = true
          return { ok = true, reason = true }, nil
        end
        return nil, 'unexpected:' .. tostring(op)
      end,
    },
  })
  artifacts:set_preflighter('mcu', function() return nil, 'bad_image' end)

  local ref, desc, err = artifacts:resolve_job_artifact({
    component = 'mcu',
    artifact = { kind = 'ref', ref = 'artifact:existing' },
  })
  assert(ref == nil and desc == nil)
  assert(err == 'bad_image')
  assert(deleted == false)
end

function T.resolve_job_artifact_deletes_non_ref_when_preflight_fails()
  local deleted = false
  local artifacts = artifacts_mod.new({
    state = { cfg = {} },
    artifact_cap = {
      call_control = function(_, op, _opts)
        if op == 'import_path' then
          return { ok = true, reason = {
            ref = function() return 'artifact:new' end,
            describe = function() return { size = 7, checksum = 'sha256:x' } end,
          } }, nil
        end
        if op == 'delete' then
          deleted = true
          return { ok = true, reason = true }, nil
        end
        return nil, 'unexpected:' .. tostring(op)
      end,
    },
  })
  artifacts:set_preflighter('mcu', function() return nil, 'bad_image' end)

  local ref, desc, err = artifacts:resolve_job_artifact({
    component = 'mcu',
    artifact = { kind = 'import_path', path = '/tmp/mcu.bin' },
  })
  assert(ref == nil and desc == nil)
  assert(err == 'bad_image')
  assert(deleted == true)
end

return T
