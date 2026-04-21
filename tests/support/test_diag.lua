local cjson = require 'cjson.safe'
local probe = require 'tests.support.bus_probe'
local stack_diag = require 'tests.support.stack_diag'

local M = {}
M.__index = M

local DEFAULT_TOPIC_GROUPS = {
  update = {
    { label = 'update', topic = { 'state', 'update', '#' } },
    { label = 'ucmd', topic = { 'cmd', 'update', '#' } },
  },
  device = {
    { label = 'device', topic = { 'state', 'device', '#' } },
    { label = 'dcmd', topic = { 'cmd', 'device', '#' } },
  },
  fabric = {
    { label = 'fabric', topic = { 'state', 'fabric', '#' } },
    { label = 'member', topic = { 'state', 'member', '#' } },
    { label = 'mcmd', topic = { 'cmd', 'member', '#' } },
  },
  config = {
    { label = 'cfg', topic = { 'cfg', '#' } },
    { label = 'ccmd', topic = { 'cmd', 'config', '#' } },
    { label = 'csvc', topic = { 'svc', 'config', '#' } },
  },
  obs = {
    { label = 'obs', topic = { 'obs', '#' } },
    { label = 'svc', topic = { 'svc', '#' } },
  },
  rpc = {
    { label = 'rpc', topic = { 'rpc', '#' } },
  },
}

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


function M.add_section(diag, section)
  diag.extra_sections[#diag.extra_sections + 1] = section
  return diag
end

function M.add_calls(diag, label, calls, opts)
  diag.extra_sections[#diag.extra_sections + 1] = { label = label, calls = calls, opts = opts }
  return diag
end

function M.add_render(diag, label, fn)
  diag.extra_sections[#diag.extra_sections + 1] = {
    render = function()
      return ('-- %s --\n%s'):format(tostring(label), tostring(fn()))
    end,
  }
  return diag
end

function M.assert_true(diag, cond, message)
  if not cond then diag:fail(message or 'assert_true failed') end
  return true
end

function M.assert_eq(diag, want, got, message)
  if want ~= got then
    diag:fail((message or 'assert_eq failed') .. ('\nwant=%s\ngot=%s'):format(encode_one(want), encode_one(got)))
  end
  return true
end

function M.for_stack(scope, bus, opts)
  opts = opts or {}
  local topics = {}
  local function add_group(name)
    local g = DEFAULT_TOPIC_GROUPS[name]
    if not g then return end
    for i = 1, #g do topics[#topics + 1] = g[i] end
  end
  if opts.update then add_group('update') end
  if opts.device then add_group('device') end
  if opts.fabric then add_group('fabric') end
  if opts.config then add_group('config') end
  if opts.obs then add_group('obs') end
  if opts.rpc then add_group('rpc') end
  if type(opts.topics) == 'table' then
    for i = 1, #opts.topics do topics[#topics + 1] = opts.topics[i] end
  end
  return M.start(scope, bus, {
    topics = topics,
    max_records = opts.max_records,
    fake_hal = opts.fake_hal,
    extra_sections = opts.extra_sections,
  })
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
