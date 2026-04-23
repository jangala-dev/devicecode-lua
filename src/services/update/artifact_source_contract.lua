local M = {}

function M.validate(name, resolver)
  if type(resolver) ~= 'table' then
    return nil, 'artifact_source_not_table:' .. tostring(name)
  end
  if type(resolver.resolve) ~= 'function' then
    return nil, 'artifact_source_missing_resolve:' .. tostring(name)
  end
  return resolver, nil
end

return M
