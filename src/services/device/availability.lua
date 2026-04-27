local M = {}

local function seen_any(states)
  if type(states) ~= 'table' then return false end
  for _, meta in pairs(states) do
    if type(meta) == 'table' and meta.seen == true then return true end
  end
  return false
end

function M.any_observation_seen(rec)
  if type(rec) ~= 'table' then return false end
  return seen_any(rec.fact_state) or seen_any(rec.event_state)
end

function M.required_facts_ready(rec, required)
  if type(required) ~= 'table' or #required == 0 then
    return M.any_observation_seen(rec)
  end
  local fact_state = type(rec) == 'table' and rec.fact_state or nil
  for i = 1, #required do
    local meta = fact_state and fact_state[required[i]] or nil
    if not (type(meta) == 'table' and meta.seen == true) then
      return false
    end
  end
  return true
end

return M
