local topics = require 'services.device.topics'

local M = {}

local function copy_array(t)
  local out = {}
  if type(t) ~= 'table' then return out end
  for i = 1, #t do out[i] = t[i] end
  return out
end

local function copy_value(v, seen)
  if type(v) ~= 'table' then return v end
  seen = seen or {}
  if seen[v] then return seen[v] end
  local out = {}
  seen[v] = out
  for k, vv in pairs(v) do
    out[copy_value(k, seen)] = copy_value(vv, seen)
  end
  return out
end

M.copy_array = copy_array
M.copy_value = copy_value

local function public_method_name(name)
  name = tostring(name or '')
  return name:gsub('_', '-')
end

M.public_method_name = public_method_name

local function is_array(t)
  if type(t) ~= 'table' then return false end
  if #t == 0 then return false end
  for k in pairs(t) do
    if type(k) ~= 'number' or k < 1 or k % 1 ~= 0 or k > #t then
      return false
    end
  end
  return true
end

local function normalize_action_routes(actions)
  local out = {}
  if type(actions) ~= 'table' then return out end

  for action_name, spec in pairs(actions) do
    if type(action_name) == 'string' and action_name ~= '' and type(spec) == 'table' then
      local public_name = public_method_name(action_name)
      if is_array(spec) then
        out[public_name] = {
          name = public_name,
          kind = 'rpc',
          call_topic = copy_array(spec),
        }
      else
        local kind = spec.kind or 'rpc'
        if kind == 'rpc' then
          local topic = spec.call_topic or spec.topic
          if is_array(topic) then
            out[public_name] = {
              name = public_name,
              kind = 'rpc',
              call_topic = copy_array(topic),
            }
          end
        elseif kind == 'fabric_stage' then
          local receiver = spec.receiver
          if type(spec.link_id) == 'string' and spec.link_id ~= '' and is_array(receiver) then
            out[public_name] = {
              name = public_name,
              kind = 'fabric_stage',
              artifact_store = spec.artifact_store or 'main',
              link_id = spec.link_id,
              receiver = copy_array(receiver),
              timeout_s = tonumber(spec.timeout_s) or nil,
            }
          end
        end
      end
    end
  end

  return out
end

local function normalize_fact_routes(facts, where)
  local out = {}
  if facts == nil then return out end
  if type(facts) ~= 'table' then error((where or 'component') .. ': facts must be a table', 0) end
  for fact_name, topic in pairs(facts) do
    if type(fact_name) ~= 'string' or fact_name == '' then
      error((where or 'component') .. ': fact names must be non-empty strings', 0)
    end
    if type(topic) ~= 'table' or #topic == 0 then
      error((where or 'component') .. ': fact ' .. tostring(fact_name) .. ' must be a non-empty topic array', 0)
    end
    out[fact_name] = { name = fact_name, watch_topic = copy_array(topic) }
  end
  return out
end


local function deep_equal(a, b, seen)
  if a == b then return true end
  if type(a) ~= type(b) then return false end
  if type(a) ~= 'table' then return false end
  seen = seen or {}
  seen[a] = seen[a] or {}
  if seen[a][b] then return true end
  seen[a][b] = true
  for k, v in pairs(a) do
    if not deep_equal(v, b[k], seen) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

local function normalize_event_routes(events, where)
  local out = {}
  if events == nil then return out end
  if type(events) ~= 'table' then error((where or 'component') .. ': events must be a table', 0) end
  for event_name, spec in pairs(events) do
    if type(event_name) ~= 'string' or event_name == '' then
      error((where or 'component') .. ': event names must be non-empty strings', 0)
    end
    local topic = spec
    if type(spec) == 'table' and spec.subscribe_topic ~= nil then
      topic = spec.subscribe_topic
    end
    if type(topic) ~= 'table' or #topic == 0 then
      error((where or 'component') .. ': event ' .. tostring(event_name) .. ' must be a non-empty topic array', 0)
    end
    out[event_name] = { name = event_name, subscribe_topic = copy_array(topic) }
  end
  return out
end

local function new_fact_state(facts)
  local raw_facts, fact_state = {}, {}
  for fact_name in pairs(facts or {}) do
    raw_facts[fact_name] = nil
    fact_state[fact_name] = { seen = false, updated_at = nil }
  end
  return raw_facts, fact_state
end

local function new_event_state(events)
  local raw_events, event_state = {}, {}
  for event_name in pairs(events or {}) do
    raw_events[event_name] = nil
    event_state[event_name] = { seen = false, updated_at = nil, count = 0 }
  end
  return raw_events, event_state
end

local function normalize_component(name, spec)
  spec = type(spec) == 'table' and spec or {}
  local facts = normalize_fact_routes(spec.facts, 'component ' .. tostring(name))
  local events = normalize_event_routes(spec.events, 'component ' .. tostring(name))
  if next(facts) == nil and next(events) == nil then
    error('component ' .. tostring(name) .. ': at least one fact or event is required', 0)
  end
  local raw_facts, fact_state = new_fact_state(facts)
  local raw_events, event_state = new_event_state(events)
  local obs_opts = spec.observe_opts or spec.provider_opts

  return {
    name = name,
    class = spec.class or 'member',
    subtype = spec.subtype or name,
    role = spec.role or 'member',
    member = spec.member or name,
    member_class = spec.member_class or spec.subtype or spec.class or name,
    link_class = spec.link_class or nil,
    present = spec.present ~= false,
    observe_opts = type(obs_opts) == 'table' and copy_value(obs_opts) or {},
    required_facts = copy_array(spec.required_facts),
    facts = facts,
    events = events,
    operations = normalize_action_routes(spec.actions),
    raw_facts = raw_facts,
    fact_state = fact_state,
    raw_events = raw_events,
    event_state = event_state,
    source_up = false,
    source_err = nil,
  }
end

local function has_facts(rec)
  return type(rec) == 'table' and type(rec.facts) == 'table' and next(rec.facts) ~= nil
end

local function has_observations(rec)
  return type(rec) == 'table' and (
    (type(rec.facts) == 'table' and next(rec.facts) ~= nil) or
    (type(rec.events) == 'table' and next(rec.events) ~= nil)
  )
end

M.has_facts = has_facts
M.has_observations = has_observations

local function default_components()
  return {
    cm5 = normalize_component('cm5', {
      class = 'host',
      subtype = 'cm5',
      role = 'primary',
      member = 'local',
      required_facts = { 'software', 'updater' },
      facts = {
        software = topics.raw_host_cap_state('updater', 'updater', 'cm5', 'software'),
        updater = topics.raw_host_cap_state('updater', 'updater', 'cm5', 'updater'),
        health = topics.raw_host_cap_state('updater', 'updater', 'cm5', 'health'),
      },
      actions = {
        ['prepare-update'] = topics.raw_host_cap_rpc('updater', 'updater', 'cm5', 'prepare'),
        ['stage-update'] = topics.raw_host_cap_rpc('updater', 'updater', 'cm5', 'stage'),
        ['commit-update'] = topics.raw_host_cap_rpc('updater', 'updater', 'cm5', 'commit'),
      },
    }),
  }
end

function M.new_state(schema)
  return {
    schema = schema,
    components = default_components(),
    dirty_components = {},
    summary_dirty = true,
  }
end

local function apply_component_overrides(base, spec)
  if type(spec.class) == 'string' and spec.class ~= '' then base.class = spec.class end
  if type(spec.subtype) == 'string' and spec.subtype ~= '' then base.subtype = spec.subtype end
  if type(spec.role) == 'string' and spec.role ~= '' then base.role = spec.role end
  if type(spec.member) == 'string' and spec.member ~= '' then base.member = spec.member end
  if type(spec.member_class) == 'string' and spec.member_class ~= '' then base.member_class = spec.member_class end
  if type(spec.link_class) == 'string' and spec.link_class ~= '' then base.link_class = spec.link_class end
  if spec.present ~= nil then base.present = spec.present ~= false end

  local obs_opts = spec.observe_opts or spec.provider_opts
  if type(obs_opts) == 'table' then
    base.observe_opts = copy_value(obs_opts)
  end
  if spec.required_facts ~= nil then
    base.required_facts = copy_array(spec.required_facts)
  end

  if spec.facts ~= nil then
    base.facts = normalize_fact_routes(spec.facts, 'component ' .. tostring(base.name))
    base.raw_facts, base.fact_state = new_fact_state(base.facts)
  end
  if spec.events ~= nil then
    base.events = normalize_event_routes(spec.events, 'component ' .. tostring(base.name))
    base.raw_events, base.event_state = new_event_state(base.events)
  end
  if next(base.facts or {}) == nil and next(base.events or {}) == nil then
    error('component ' .. tostring(base.name) .. ': at least one fact or event is required', 0)
  end
  if type(spec.actions) == 'table' then
    base.operations = normalize_action_routes(spec.actions)
  end

  base.source_up = false
  base.source_err = nil
  return base
end

function M.merge_components(cfg, schema)
  local out = default_components()
  if type(cfg) ~= 'table' then return out end
  if cfg.schema ~= nil and cfg.schema ~= schema then return out end
  local comps = cfg.components or {}
  if type(comps) ~= 'table' then return out end
  for name, spec in pairs(comps) do
    if type(name) == 'string' and type(spec) == 'table' then
      local base = out[name] or normalize_component(name, spec)
      out[name] = apply_component_overrides(base, spec)
    end
  end
  return out
end

function M.apply_cfg(state, payload)
  local data = payload and (payload.data or payload) or nil
  state.components = M.merge_components(data, state.schema)
  for name in pairs(state.components) do
    state.dirty_components[name] = true
  end
  state.summary_dirty = true
end

function M.note_fact(state, name, fact_name, payload, updated_at)
  local rec = state.components[name]
  if not rec or not has_facts(rec) or type(fact_name) ~= 'string' or fact_name == '' then
    return nil
  end
  rec.fact_state[fact_name] = rec.fact_state[fact_name] or { seen = false, updated_at = nil }
  local fst = rec.fact_state[fact_name]
  local changed = (not fst.seen)
    or (updated_at ~= nil and fst.updated_at ~= updated_at)
    or (not deep_equal(rec.raw_facts[fact_name], payload))
    or rec.source_up ~= true
    or rec.source_err ~= nil

  rec.raw_facts[fact_name] = payload
  fst.seen = true
  fst.updated_at = updated_at or fst.updated_at
  rec.source_up = true
  rec.source_err = nil

  if changed then
    state.dirty_components[name] = true
    state.summary_dirty = true
  end
  return rec
end

function M.note_event(state, name, event_name, payload, updated_at)
  local rec = state.components[name]
  if not rec or type(event_name) ~= 'string' or event_name == '' then
    return nil
  end
  rec.raw_events = rec.raw_events or {}
  rec.event_state = rec.event_state or {}
  rec.raw_events[event_name] = payload
  local st = rec.event_state[event_name] or { seen = false, updated_at = nil, count = 0 }
  st.seen = true
  st.updated_at = updated_at or st.updated_at
  st.count = (st.count or 0) + 1
  rec.event_state[event_name] = st
  rec.source_up = true
  rec.source_err = nil
  state.dirty_components[name] = true
  state.summary_dirty = true
  return rec
end

function M.note_source_down(state, name, reason)
  local rec = state.components[name]
  if not rec then return nil end
  local changed = rec.source_up ~= false or rec.source_err ~= reason
  rec.source_up = false
  rec.source_err = reason
  if changed then
    state.dirty_components[name] = true
    state.summary_dirty = true
  end
  return rec
end

function M.mark_all_dirty(state)
  for name in pairs(state.components) do
    state.dirty_components[name] = true
  end
  state.summary_dirty = true
end

function M.clear_component_dirty(state, name)
  state.dirty_components[name] = nil
end

function M.set_summary_clean(state)
  state.summary_dirty = false
end

return M
