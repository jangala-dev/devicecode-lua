local contract = require 'services.update.artifact_source_contract'

local M = {}

local SOURCES = {
  import_path = {
    resolve = function(artifacts, component, artifact, metadata)
      if type(artifact.path) ~= 'string' or artifact.path == '' then
        return nil, nil, 'invalid_artifact_path'
      end
      return artifacts:import_path(artifact.path, component, metadata)
    end,
  },
  ref = {
    resolve = function(artifacts, _component, artifact)
      if type(artifact.ref) ~= 'string' or artifact.ref == '' then
        return nil, nil, 'invalid_artifact_ref'
      end
      local stored, derr = artifacts:open(artifact.ref)
      if not stored then return nil, nil, derr end
      local desc, derr2 = artifacts:describe_artifact(stored)
      if not desc then return nil, nil, derr2 end
      return artifact.ref, desc, nil
    end,
  },
  bundled = {
    resolve = function(artifacts, component, artifact, metadata)
      return artifacts:import_bundled(component, artifact, metadata)
    end,
  },
}

function M.register(kind, resolver)
  local r, err = contract.validate(kind, resolver)
  if not r then return nil, err end
  SOURCES[kind] = r
  return true, nil
end

function M.resolve(artifacts, component, artifact, metadata)
  if type(artifact) ~= 'table' then
    return nil, nil, 'artifact_required'
  end
  local kind = artifact.kind
  if type(kind) ~= 'string' or kind == '' then
    return nil, nil, 'invalid_artifact_kind'
  end
  local resolver = SOURCES[kind]
  if not resolver then return nil, nil, 'invalid_artifact_kind' end
  return resolver.resolve(artifacts, component, artifact, metadata)
end

return M
