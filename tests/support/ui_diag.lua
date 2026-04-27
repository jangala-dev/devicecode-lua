local cjson = require 'cjson.safe'

local M = {}

local function enc(v)
  local ok, s = pcall(cjson.encode, v)
  if ok and s then return s end
  return tostring(v)
end

local function add(out, label, fn)
  if not fn then return end
  local ok, v = pcall(fn)
  if ok then
    out[#out + 1] = label .. '=' .. enc(v)
  else
    out[#out + 1] = label .. '=<error:' .. tostring(v) .. '>'
  end
end

function M.render(opts)
  opts = opts or {}
  local out = { '-- ui diag --' }
  add(out, 'main', opts.main_fn)
  add(out, 'snapshot', opts.snapshot_fn)
  add(out, 'sessions', opts.sessions_fn)
  add(out, 'config_net', opts.config_net_fn)
  add(out, 'services', opts.services_fn)
  add(out, 'fabric', opts.fabric_fn)
  add(out, 'extra', opts.extra_fn)
  return table.concat(out, '\n')
end

return M
