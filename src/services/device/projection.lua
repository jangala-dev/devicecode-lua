local model = require 'services.device.model'
local component_host = require 'services.device.component_host'
local component_mcu = require 'services.device.component_mcu'
local topics = require 'services.device.topics'
local availability = require 'services.device.availability'

local M = {}

function M.identity_topic()
  return topics.identity()
end

function M.component_topic(name)
  return topics.component(name)
end

function M.component_software_topic(name)
  return topics.component_software(name)
end

function M.component_update_topic(name)
  return topics.component_update(name)
end

function M.summary_topic()
  return topics.components()
end


function M.component_cap_topic(name, method)
  return topics.component_cap_rpc(name, method)
end

function M.component_cap_meta_topic(name)
  return topics.component_cap_meta(name)
end

function M.component_cap_status_topic(name)
  return topics.component_cap_status(name)
end

function M.component_cap_event_topic(name, event)
  return topics.component_cap_event(name, event)
end


local function copy(t)
  return model.copy_value(t)
end

local function public_actions(rec)
  local actions = {}
  for action_name in pairs(rec.operations or {}) do
    actions[action_name] = true
  end
  return actions
end

local function compose_component(rec)
  local subtype = rec and (rec.subtype or rec.member_class or rec.name) or nil
  if subtype == 'mcu' then
    return component_mcu.compose(rec.raw_facts or {}, rec.raw_events or {})
  end
  return component_host.compose(rec.raw_facts or {})
end

local function derive_source(rec)
  return {
    kind = (rec.class == 'host') and 'host' or 'member',
    member = rec.member,
    member_class = rec.member_class,
    link_class = rec.link_class,
    role = rec.role,
  }
end

local function derive_health(available, updater_state, explicit_health)
  if explicit_health ~= nil then return explicit_health end
  if not available then return 'unknown' end
  if updater_state == 'failed' or updater_state == 'unavailable' then
    return 'degraded'
  end
  return 'ok'
end

local function public_status(rec)
  local source_up = rec.source_up == true
  local seen = availability.any_observation_seen(rec)
  local ready = availability.required_facts_ready(rec, rec.required_facts)
  local available = source_up and seen
  if source_up and not seen and type(rec.events) == 'table' and next(rec.events) ~= nil and not model.has_facts(rec) then
    available = true
    ready = true
  end
  return available, available and ready
end

function M.component_view(name, rec, now_ts)
  local base = compose_component(rec)
  local actions = public_actions(rec)
  local available, ready = public_status(rec)
  local updater_state = type(base.updater) == 'table' and base.updater.state or nil
  local health = derive_health(available, updater_state, base.health)

  return {
    kind = 'device.component',
    ts = now_ts,
    component = name,
    class = rec.class,
    subtype = rec.subtype,
    role = rec.role,
    member = rec.member,
    member_class = rec.member_class,
    link_class = rec.link_class,
    present = rec.present ~= false,
    available = available,
    ready = ready,
    health = health,
    actions = actions,
    software = copy(base.software),
    updater = copy(base.updater),
    power = copy(base.power or {}),
    environment = copy(base.environment or {}),
    runtime = copy(base.runtime or {}),
    alerts = copy(base.alerts or {}),
    source = derive_source(rec),
  }
end

function M.component_payloads(name, rec, now_ts)
  local view = M.component_view(name, rec, now_ts)

  local sw = copy(view.software)
  sw.kind = 'device.component.software'
  sw.ts = now_ts
  sw.component = name
  sw.role = view.role
  sw.member = view.member
  sw.member_class = view.member_class
  sw.link_class = view.link_class

  local upd = copy(view.updater)
  upd.kind = 'device.component.update'
  upd.ts = now_ts
  upd.component = name
  upd.available = view.available
  upd.health = view.health
  upd.actions = view.actions

  return {
    component = view,
    software = sw,
    update = upd,
  }
end

function M.summary_payload(state, now_ts)
  local items = {}
  local counts = { total = 0, available = 0, degraded = 0 }

  for name, rec in pairs(state.components) do
    local view = M.component_view(name, rec, now_ts)
    counts.total = counts.total + 1
    if view.available then counts.available = counts.available + 1 end
    if view.health ~= 'ok' then counts.degraded = counts.degraded + 1 end
    items[name] = {
      class = view.class,
      subtype = view.subtype,
      role = view.role,
      member = view.member,
      member_class = view.member_class,
      link_class = view.link_class,
      present = view.present,
      available = view.available,
      ready = view.ready,
      health = view.health,
      actions = view.actions,
      software = copy(view.software),
      updater = copy(view.updater),
      power = copy(view.power),
      environment = copy(view.environment),
      runtime = copy(view.runtime),
      alerts = copy(view.alerts),
    }
  end

  return {
    kind = 'device.components',
    ts = now_ts,
    components = items,
    counts = counts,
  }
end

function M.self_payload(state, now_ts)
  local summary = M.summary_payload(state, now_ts)
  return {
    kind = 'device.identity',
    ts = now_ts,
    counts = summary.counts,
    components = summary.components,
  }
end

function M.software_payload(name, rec, now_ts)
  return M.component_payloads(name, rec, now_ts).software
end

function M.update_payload(name, rec, now_ts)
  return M.component_payloads(name, rec, now_ts).update
end

return M
