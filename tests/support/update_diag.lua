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
  local out = { '-- update diag --' }
  add(out, 'service', opts.service_fn)
  add(out, 'summary', opts.summary_fn)
  add(out, 'jobs', opts.jobs_fn)
  add(out, 'active_job', opts.active_job_fn)
  add(out, 'store', opts.store_fn)
  add(out, 'artifacts', opts.artifacts_fn)
  add(out, 'backend', opts.backend_fn)
  add(out, 'extra', opts.extra_fn)
  return table.concat(out, '\n')
end

return M
