local cjson = require 'cjson.safe'
local probe = require 'tests.support.bus_probe'
local stack_diag = require 'tests.support.stack_diag'
local update_diag = require 'tests.support.update_diag'
local device_diag = require 'tests.support.device_diag'
local ui_diag = require 'tests.support.ui_diag'
local fabric_diag = require 'tests.support.fabric_diag'

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
  ui = {
    { label = 'ui', topic = { 'state', 'ui', '#' } },
  },
}

local SUBSYSTEM_RENDERERS = {
  update = update_diag,
  device = device_diag,
  ui = ui_diag,
  fabric = fabric_diag,
}

local function shallow_merge(a, b)
  local out = {}
  if type(a) == 'table' then
    for k, v in pairs(a) do out[k] = v end
  end
  if type(b) == 'table' then
    for k, v in pairs(b) do out[k] = v end
  end
  return out
end

local function make_subsystem_section(kind, opts)
  local renderer = SUBSYSTEM_RENDERERS[kind]
  assert(renderer and type(renderer.render) == 'function', 'unknown subsystem renderer: ' .. tostring(kind))
  return {
    render = function()
      return renderer.render(opts or {})
    end,
  }
end

local STACK_PROFILES = {}

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

local function render_table(label, value)
  return ('-- %s --\n%s'):format(tostring(label), encode_one(value))
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

function M.add_table(diag, label, value_fn)
  diag.extra_sections[#diag.extra_sections + 1] = {
    render = function()
      local value = (type(value_fn) == 'function') and value_fn() or value_fn
      return render_table(label, value)
    end,
  }
  return diag
end

function M.add_subsystem(diag, kind, opts)
  diag.extra_sections[#diag.extra_sections + 1] = make_subsystem_section(kind, opts)
  return diag
end

function M.retained_fn(conn, topic, opts)
  opts = opts or {}
  return function()
    local ok, payload = pcall(function()
      return probe.wait_payload(conn, topic, { timeout = opts.timeout or 0.01 })
    end)
    if ok then return payload end
    return { __error = tostring(payload), topic = topic }
  end
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

function M.assert_match(diag, got, partial, message)
  if type(got) ~= 'table' or type(partial) ~= 'table' then
    diag:fail((message or 'assert_match failed') .. ('\nwant_partial=%s\ngot=%s'):format(encode_one(partial), encode_one(got)))
  end
  for k, v in pairs(partial) do
    if got[k] ~= v then
      diag:fail((message or 'assert_match failed') .. ('\nkey=%s\nwant=%s\ngot=%s\nfull=%s'):format(tostring(k), encode_one(v), encode_one(got[k]), encode_one(got)))
    end
  end
  return true
end

function M.assert_eventually_eq(diag, label, getter, want, opts)
  local got
  diag:assert_until((label or 'assert_eventually_eq failed') .. ('\nwant=%s\ngot=%s'):format(encode_one(want), encode_one(got)), function()
    got = getter()
    return got == want
  end, opts)
  return true
end

function M.assert_no_event(diag, pred, window_s, message)
  local ok = probe.wait_until(function()
    return pred() == true
  end, { timeout = window_s or 0.1, interval = 0.01 })
  if ok then
    diag:fail(message or 'assert_no_event failed: observed forbidden event')
  end
  return true
end


STACK_PROFILES.update_stack = function(opts)
  opts = opts or {}
  local conn = assert(opts.conn, 'update_stack profile requires opts.conn')
  local link_id = opts.link_id or 'cm5-uart-mcu'
  local member_id = opts.member_id or 'mcu'
  local stack = shallow_merge({ update = true, device = true, fabric = true, max_records = opts.max_records }, opts.stack)
  local sections = {
    make_subsystem_section('update', shallow_merge({
      service_fn = opts.service_fn or M.retained_fn(conn, { 'svc', 'update', 'status' }),
      summary_fn = opts.summary_fn or M.retained_fn(conn, { 'state', 'update', 'summary' }),
      jobs_fn = opts.jobs_fn,
      active_job_fn = opts.active_job_fn,
      store_fn = opts.store_fn or function() return opts.control and opts.control.namespaces['update/jobs'] or nil end,
      artifacts_fn = opts.artifacts_fn or function() return opts.artifacts and opts.artifacts.artifacts or nil end,
      backend_fn = opts.backend_fn,
      extra_fn = opts.update_extra_fn,
    }, opts.update)),
    make_subsystem_section('device', shallow_merge({
      service_fn = opts.device_service_fn or M.retained_fn(conn, { 'svc', 'device', 'status' }),
      summary_fn = opts.device_summary_fn or M.retained_fn(conn, { 'state', 'device' }),
      cm5_fn = opts.cm5_fn or M.retained_fn(conn, { 'state', 'device', 'component', opts.cm5_component or 'cm5' }),
      mcu_fn = opts.mcu_fn or M.retained_fn(conn, { 'state', 'device', 'component', opts.mcu_component or 'mcu' }),
      extra_fn = opts.device_extra_fn,
    }, opts.device)),
    make_subsystem_section('fabric', shallow_merge({
      service_fn = opts.fabric_service_fn or M.retained_fn(conn, { 'svc', 'fabric', 'status' }),
      summary_fn = opts.fabric_summary_fn or M.retained_fn(conn, { 'state', 'fabric' }),
      session_fn = opts.session_fn or M.retained_fn(conn, { 'state', 'fabric', 'link', link_id, 'session' }),
      transfer_fn = opts.transfer_fn or M.retained_fn(conn, { 'state', 'fabric', 'link', link_id, 'transfer' }),
      member_fn = opts.member_fn or M.retained_fn(conn, { 'state', 'member', member_id, 'updater' }),
      extra_fn = opts.fabric_extra_fn,
    }, opts.fabric)),
  }
  return { stack = stack, sections = sections }
end

STACK_PROFILES.device_stack = function(opts)
  opts = opts or {}
  local conn = assert(opts.conn, 'device_stack profile requires opts.conn')
  local stack = shallow_merge({ device = true, max_records = opts.max_records }, opts.stack)
  local sections = {
    make_subsystem_section('device', shallow_merge({
      service_fn = opts.device_service_fn or M.retained_fn(conn, { 'svc', 'device', 'status' }),
      summary_fn = opts.device_summary_fn or M.retained_fn(conn, { 'state', 'device' }),
      cm5_fn = opts.cm5_fn or M.retained_fn(conn, { 'state', 'device', 'component', opts.cm5_component or 'cm5' }),
      mcu_fn = opts.mcu_fn or M.retained_fn(conn, { 'state', 'device', 'component', opts.mcu_component or 'mcu' }),
      extra_fn = opts.device_extra_fn,
    }, opts.device)),
  }
  return { stack = stack, sections = sections }
end

STACK_PROFILES.fabric_stack = function(opts)
  opts = opts or {}
  local conn = assert(opts.conn, 'fabric_stack profile requires opts.conn')
  local link_id = opts.link_id or 'cm5-uart-mcu'
  local member_id = opts.member_id or 'mcu'
  local stack = shallow_merge({ fabric = true, max_records = opts.max_records }, opts.stack)
  local sections = {
    make_subsystem_section('fabric', shallow_merge({
      service_fn = opts.fabric_service_fn or M.retained_fn(conn, { 'svc', 'fabric', 'status' }),
      summary_fn = opts.fabric_summary_fn or M.retained_fn(conn, { 'state', 'fabric' }),
      session_fn = opts.session_fn or M.retained_fn(conn, { 'state', 'fabric', 'link', link_id, 'session' }),
      transfer_fn = opts.transfer_fn or M.retained_fn(conn, { 'state', 'fabric', 'link', link_id, 'transfer' }),
      member_fn = opts.member_fn or M.retained_fn(conn, { 'state', 'member', member_id, 'updater' }),
      extra_fn = opts.fabric_extra_fn,
    }, opts.fabric)),
  }
  return { stack = stack, sections = sections }
end

STACK_PROFILES.ui_stack = function(opts)
  opts = opts or {}
  local conn = assert(opts.conn, 'ui_stack profile requires opts.conn')
  local stack = shallow_merge({ ui = true, config = true, obs = true, rpc = true, max_records = opts.max_records }, opts.stack)
  local sections = {
    make_subsystem_section('ui', shallow_merge({
      main_fn = opts.main_fn or M.retained_fn(conn, { 'state', 'ui', 'main' }),
      config_net_fn = opts.config_net_fn or M.retained_fn(conn, { 'cfg', 'net' }),
      services_fn = opts.services_fn,
      fabric_fn = opts.fabric_fn or M.retained_fn(conn, { 'state', 'fabric' }),
      extra_fn = opts.ui_extra_fn,
    }, opts.ui)),
  }
  return { stack = stack, sections = sections }
end

function M.start_profile(scope, bus, name, opts)
  local builder = STACK_PROFILES[name]
  assert(type(builder) == 'function', 'unknown stack profile: ' .. tostring(name))
  local spec = builder(opts or {})
  local diag = M.for_stack(scope, bus, spec.stack or {})
  for i = 1, #(spec.sections or {}) do
    diag.extra_sections[#diag.extra_sections + 1] = spec.sections[i]
  end
  if type(spec.extra_sections) == 'table' then
    for i = 1, #spec.extra_sections do
      diag.extra_sections[#diag.extra_sections + 1] = spec.extra_sections[i]
    end
  end
  return diag
end

M.for_stack_profile = M.start_profile

local function value_key(v)
  return encode_one(v)
end

function M.assert_transitions(diag, label, getter, expected, opts)
  opts = opts or {}
  local timeout = opts.timeout or 1.0
  local interval = opts.interval or 0.005
  local selector = opts.selector or function(v) return v end
  local matches = opts.matches or function(got, want) return got == want end
  local ignore_nil = (opts.ignore_nil ~= false)
  local allow_other = (opts.allow_other ~= false)
  local collapse = (opts.collapse ~= false)
  local history = {}
  local idx = 1
  local last_key = nil

  local function maybe_record(v)
    local key = value_key(v)
    if not collapse or key ~= last_key then
      history[#history + 1] = v
      last_key = key
    end
  end

  local ok = probe.wait_until(function()
    local got_ok, raw = pcall(getter)
    if not got_ok then return false end
    local got = selector(raw)
    if got == nil and ignore_nil then return false end
    maybe_record(got)
    if matches(got, expected[idx]) then
      idx = idx + 1
      return idx > #expected
    end
    if not allow_other then
      return false
    end
    return false
  end, { timeout = timeout, interval = interval })

  if not ok or idx <= #expected then
    diag:fail((label or 'assert_transitions failed')
      .. ('\nexpected=%s\nobserved=%s'):format(encode_one(expected), encode_one(history)))
  end

  return history
end

function M.assert_retained_transitions(diag, conn, topic, expected, opts)
  opts = opts or {}
  local getter = M.retained_fn(conn, topic, { timeout = opts.sample_timeout or 0.02 })
  return M.assert_transitions(diag, opts.label or ('retained transitions for ' .. encode_one(topic)), getter, expected, opts)
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
  if opts.ui then add_group('ui') end
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
M.render_table = render_table

return M
