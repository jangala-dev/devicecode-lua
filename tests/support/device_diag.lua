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
  local out = { '-- device diag --' }
  add(out, 'service', opts.service_fn)
  add(out, 'summary', opts.summary_fn)
  add(out, 'components', opts.components_fn)
  add(out, 'sources', opts.sources_fn)
  add(out, 'component_cm5', opts.cm5_fn)
  add(out, 'component_mcu', opts.mcu_fn)
  add(out, 'extra', opts.extra_fn)
  return table.concat(out, '\n')
end

return M
