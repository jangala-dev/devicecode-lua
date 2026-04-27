local M = {}

local SOURCES = {
  import_path = {
    resolve = function(artifacts, component, artifact, metadata)
      if type(artifact.path) ~= 'string' or artifact.path == '' then
        return nil, nil, nil, 'invalid_artifact_path'
      end
      local ref, desc, err = artifacts:import_path(artifact.path, component, metadata)
      if not ref then return nil, nil, nil, err end
      return ref, desc, true, nil
    end,
  },
  ref = {
    resolve = function(artifacts, _component, artifact)
      if type(artifact.ref) ~= 'string' or artifact.ref == '' then
        return nil, nil, nil, 'invalid_artifact_ref'
      end
      local stored, derr = artifacts:open(artifact.ref)
      if not stored then return nil, nil, nil, derr end
      local desc, derr2 = artifacts:describe_artifact(stored)
      if not desc then return nil, nil, nil, derr2 end
      return artifact.ref, desc, false, nil
    end,
  },
  bundled = {
    resolve = function(artifacts, component, artifact, metadata)
      local ref, desc, err = artifacts:import_bundled(component, artifact, metadata)
      if not ref then return nil, nil, nil, err end
      return ref, desc, true, nil
    end,
  },
}

function M.register(kind, resolver)
  if type(kind) ~= 'string' or kind == '' then
    return nil, 'invalid_artifact_kind'
  end
  if type(resolver) ~= 'table' then
    return nil, 'artifact_source_not_table:' .. tostring(kind)
  end
  if type(resolver.resolve) ~= 'function' then
    return nil, 'artifact_source_missing_resolve:' .. tostring(kind)
  end
  SOURCES[kind] = resolver
  return true, nil
end

function M.resolve(artifacts, component, artifact, metadata)
  if type(artifact) ~= 'table' then
    return nil, nil, nil, 'artifact_required'
  end
  local kind = artifact.kind
  if type(kind) ~= 'string' or kind == '' then
    return nil, nil, nil, 'invalid_artifact_kind'
  end
  local resolver = SOURCES[kind]
  if not resolver then return nil, nil, nil, 'invalid_artifact_kind' end

  return resolver.resolve(artifacts, component, artifact, metadata)
end

return M
