local cjson = require 'cjson.safe'

local M = {}

local function read_file(path)
  local f = assert(io.open(path, 'rb'))
  local s = assert(f:read('*a'))
  f:close()
  return s
end

function M.load_profile(path)
  local chunk = assert(loadfile(path))
  local rec = assert(chunk())
  assert(type(rec) == 'table', 'profile must return table')
  return rec
end

function M.load_config_json(path)
  local cfg = assert(cjson.decode(read_file(path)))
  assert(type(cfg) == 'table', 'config must decode to table')
  return cfg
end

function M.validate_profile_services(profile, spec)
  local services = type(profile) == 'table' and profile.services or nil
  if type(services) ~= 'table' then
    return nil, 'profile_missing_services'
  end
  local seen = {}
  for i = 1, #services do
    local name = services[i]
    if seen[name] then return nil, 'duplicate_service:' .. tostring(name) end
    seen[name] = true
  end
  spec = type(spec) == 'table' and spec or {}
  for i = 1, #(spec.required or {}) do
    local name = spec.required[i]
    if not seen[name] then return nil, 'missing_required_service:' .. tostring(name) end
  end
  for i = 1, #(spec.forbidden or {}) do
    local name = spec.forbidden[i]
    if seen[name] then return nil, 'forbidden_service_present:' .. tostring(name) end
  end
  return seen, nil
end

function M.require_path(tbl, path)
  local cur = tbl
  for i = 1, #path do
    if type(cur) ~= 'table' then return nil, 'missing_path:' .. table.concat(path, '.') end
    cur = cur[path[i]]
  end
  if cur == nil then return nil, 'missing_path:' .. table.concat(path, '.') end
  return cur, nil
end

return M
