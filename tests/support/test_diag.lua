local cjson = require 'cjson.safe'
local probe = require 'tests.support.bus_probe'
local stack_diag = require 'tests.support.stack_diag'

local M = {}
M.__index = M

local function encode_one(v)
  local ok, s = pcall(cjson.encode, v)
  if ok and s then return s end
  return tostring(v)
end

local function render_calls(label, calls, opts)
  opts = opts or {}
  local max_calls = opts.max_calls or 80
  calls = calls or {}
  local start_idx = math.max(1, #calls - max_calls + 1)
  local out = {}
  out[#out + 1] = ('%s=%d'):format(tostring(label), #calls)
  out[#out + 1] = ('-- %s --'):format(tostring(label))
  for i = start_idx, #calls do
    local c = calls[i]
    if type(c) == 'table' then
      out[#out + 1] = ('[%d] %s'):format(i, encode_one(c))
    else
      out[#out + 1] = ('[%d] %s'):format(i, tostring(c))
    end
  end
  return table.concat(out, '\n')
end

function M.start(scope, bus, opts)
  opts = opts or {}
  local rec = stack_diag.start(scope, bus, opts.topics or {}, { max_records = opts.max_records })
  return setmetatable({
    rec = rec,
    fake_hal = opts.fake_hal,
    extra_sections = opts.extra_sections or {},
  }, M)
end

function M:render(message)
  local parts = {
    tostring(message),
    '',
    stack_diag.render(self.rec),
  }
  if self.fake_hal then
    parts[#parts + 1] = ''
    parts[#parts + 1] = stack_diag.render_fake_hal(self.fake_hal)
  end
  for i = 1, #self.extra_sections do
    local sec = self.extra_sections[i]
    parts[#parts + 1] = ''
    if type(sec) == 'function' then
      parts[#parts + 1] = tostring(sec())
    elseif type(sec) == 'table' and sec.render then
      parts[#parts + 1] = tostring(sec.render())
    elseif type(sec) == 'table' and sec.calls then
      parts[#parts + 1] = render_calls(sec.label or ('calls' .. tostring(i)), sec.calls, sec.opts)
    else
      parts[#parts + 1] = tostring(sec)
    end
  end
  return table.concat(parts, '\n')
end

function M:fail(message)
  error(self:render(message), 0)
end

function M:assert_until(message, pred, opts)
  if not probe.wait_until(pred, opts) then
    self:fail(message)
  end
end

M.render_calls = render_calls

return M
