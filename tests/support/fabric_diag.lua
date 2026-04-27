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
  local out = { '-- fabric diag --' }
  add(out, 'service', opts.service_fn)
  add(out, 'summary', opts.summary_fn)
  add(out, 'session', opts.session_fn)
  add(out, 'bridge', opts.bridge_fn)
  add(out, 'transfer', opts.transfer_fn)
  add(out, 'member', opts.member_fn)
  add(out, 'writer', opts.writer_fn)
  add(out, 'extra', opts.extra_fn)
  return table.concat(out, '\n')
end

return M
