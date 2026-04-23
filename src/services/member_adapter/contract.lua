local M = {}

local function copy_array(t)
  local out = {}
  if type(t) ~= 'table' then return out end
  for i = 1, #t do out[i] = t[i] end
  return out
end

function M.validate_spec(name, spec)
  if type(spec) ~= 'table' then
    return nil, 'adapter_spec_not_table:' .. tostring(name)
  end
  if type(spec.member) ~= 'string' or spec.member == '' then
    return nil, 'adapter_spec_missing_member:' .. tostring(name)
  end
  local out = {
    name = name,
    member = spec.member,
    facts = {},
    events = {},
  }
  if type(spec.facts) == 'table' then
    for fact_name, suffix in pairs(spec.facts) do
      if type(fact_name) == 'string' and type(suffix) == 'table' and #suffix > 0 then
        out.facts[fact_name] = copy_array(suffix)
      end
    end
  end
  if type(spec.events) == 'table' then
    for event_name, suffix in pairs(spec.events) do
      if type(event_name) == 'string' and type(suffix) == 'table' and #suffix > 0 then
        out.events[event_name] = copy_array(suffix)
      end
    end
  end
  return out, nil
end

return M
