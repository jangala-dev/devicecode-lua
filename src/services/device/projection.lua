-- services/device/projection.lua
--
-- Pure projection from Device model state to public payloads.

local model = require 'services.device.model'
local host  = require 'services.device.component_host'
local mcu   = require 'services.device.component_mcu'
local topics = require 'services.device.topics'
local availability = require 'services.device.availability'

local M = {}

function M.identity_topic() return topics.identity() end
function M.summary_topic() return topics.components() end
function M.component_topic(name) return topics.component(name) end
function M.component_software_topic(name) return topics.component_software(name) end
function M.component_update_topic(name) return topics.component_update(name) end
function M.component_cap_topic(name, method) return topics.component_cap_rpc(name, method) end
function M.component_cap_meta_topic(name) return topics.component_cap_meta(name) end
function M.component_cap_status_topic(name) return topics.component_cap_status(name) end
function M.component_cap_event_topic(name, event) return topics.component_cap_event(name, event) end
function M.wired_provider_cap_meta_topic(id) return topics.wired_provider_cap_meta(id) end
function M.wired_provider_cap_status_topic(id) return topics.wired_provider_cap_status(id) end
function M.wired_provider_cap_state_topic(id, key) return topics.wired_provider_cap_state(id, key) end

local function copy(v)
	return model.copy_value(v)
end

local function public_actions(rec)
	local actions = { ['get-status'] = true }
	for action_name in pairs(rec.actions or {}) do
		actions[action_name] = true
	end
	return actions
end

local function compose_component(rec)
	local mod = type(rec) == 'table' and rec.module or nil
	if type(mod) == 'table' and type(mod.compose) == 'function' then
		return mod.compose(rec.raw_facts or {}, rec.raw_events or {})
	end
	local subtype = rec and (rec.subtype or rec.member_class or rec.name) or nil
	if subtype == 'mcu' or rec.class == 'mcu' then
		return mcu.compose(rec.raw_facts or {}, rec.raw_events or {})
	end
	return host.compose(rec.raw_facts or {})
end


local function copy_topic(v)
	if type(v) ~= 'table' then return nil end
	local out = {}
	for i = 1, #v do out[i] = v[i] end
	return out
end

local function fact_backing_topic(spec)
	if type(spec) == 'table' and spec.watch_topic ~= nil then return spec.watch_topic end
	return spec
end

local function event_backing_topic(spec)
	if type(spec) == 'table' and spec.subscribe_topic ~= nil then return spec.subscribe_topic end
	return spec
end

local function collect_backing_refs(rec)
	local refs = { facts = {}, events = {}, actions = {} }
	for name, spec in pairs(rec.facts or {}) do
		refs.facts[name] = copy_topic(fact_backing_topic(spec))
	end
	for name, spec in pairs(rec.events or {}) do
		refs.events[name] = copy_topic(event_backing_topic(spec))
	end
	for name, spec in pairs(rec.actions or {}) do
		if type(spec) == 'table' and spec.call_topic then
			refs.actions[name] = copy_topic(spec.call_topic)
		elseif type(spec) == 'table' and spec.receiver then
			refs.actions[name] = copy_topic(spec.receiver)
		else
			refs.actions[name] = copy_topic(spec)
		end
	end
	return refs
end

local function derive_source(rec)
	return {
		kind = (rec.class == 'host') and 'host' or 'member',
		member = rec.member,
		member_class = rec.member_class,
		link_class = rec.link_class,
		role = rec.role,
		reason = rec.source_err,
	}
end

local function derive_health(status, updater_state, explicit_health)
	if explicit_health ~= nil then return explicit_health end
	if status.health ~= nil and status.health ~= 'unknown' then return status.health end
	if not status.available then return 'unknown' end
	if updater_state == 'failed' or updater_state == 'unavailable' then return 'degraded' end
	return 'ok'
end

function M.component_view(name, rec, now_ts)
	rec = rec or {}
	local base = compose_component(rec)
	local status = rec.status or availability.component_status(rec)
	local updater_state = type(base.updater) == 'table' and base.updater.state or nil
	local health = derive_health(status, updater_state, base.health)

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
		display = copy(rec.display or {}),
		present = rec.present ~= false,
		availability = status.availability,
		available = status.available,
		ready = status.ready,
		health = health,
		reason = status.reason,
		actions = public_actions(rec),
		software = copy(base.software or {}),
		updater = copy(base.updater or {}),
		power = copy(base.power or {}),
		environment = copy(base.environment or {}),
		runtime = copy(base.runtime or {}),
		alerts = copy(base.alerts or {}),
		wired_provider = copy(base.wired_provider),
		source = derive_source(rec),
		last_action = copy(rec.last_action),
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
	upd.actions = copy(view.actions)

	return {
		component = view,
		software = sw,
		update = upd,
		cap_meta = {
			owner = 'device',
			interface = 'devicecode.cap/component/1',
			component = name,
			methods = copy(view.actions),
			events = { ['state-changed'] = true },
			canonical_state = M.component_topic(name),
			backing_source = copy(view.source),
			backing = collect_backing_refs(rec),
		},
		cap_status = {
			state = view.availability or (view.available and 'available' or 'unavailable'),
			availability = view.availability,
			available = view.available,
			health = view.health,
			ready = view.ready,
			reason = view.reason,
		},
		wired_provider = view.wired_provider and {
			id = name,
			meta = {
				owner = 'device',
				interface = 'devicecode.cap/wired-provider/1',
				component = name,
				canonical_state = M.component_topic(name),
				backing_source = copy(view.source),
				backing = collect_backing_refs(rec),
				mode = view.wired_provider.status and view.wired_provider.status.mode or nil,
			},
			status = {
				state = (view.wired_provider.status and view.wired_provider.status.state)
					or view.availability
					or (view.available and 'available' or 'unavailable'),
				available = view.wired_provider.status and view.wired_provider.status.available,
				health = view.health,
				reason = view.reason
					or (view.wired_provider.status and (
						view.wired_provider.status.reason
						or view.wired_provider.status.err
					)),
				mode = view.wired_provider.status and view.wired_provider.status.mode or nil,
			},
			surfaces = { surfaces = copy(view.wired_provider.surfaces or {}) },
			topology = copy(view.wired_provider.topology or {}),
		} or nil,
	}
end

function M.summary_payload(snapshot, now_ts)
	local items = {}
	local counts = { total = 0, available = 0, degraded = 0 }

	for name, rec in pairs((snapshot and snapshot.components) or {}) do
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
			availability = view.availability,
			available = view.available,
			ready = view.ready,
			health = view.health,
			reason = view.reason,
			actions = copy(view.actions),
			software = copy(view.software),
			updater = copy(view.updater),
			power = copy(view.power),
			environment = copy(view.environment),
			runtime = copy(view.runtime),
			alerts = copy(view.alerts),
			wired_provider = copy(view.wired_provider),
		}
	end

	return {
		kind = 'device.components',
		ts = now_ts,
		generation = snapshot and snapshot.generation or nil,
		components = items,
		counts = counts,
	}
end

function M.identity_payload(snapshot, now_ts)
	local summary = M.summary_payload(snapshot, now_ts)
	return {
		kind = 'device.identity',
		ts = now_ts,
		generation = snapshot and snapshot.generation or nil,
		counts = summary.counts,
		components = summary.components,
	}
end

function M.state_changed_event(name, rec, now_ts)
	local payloads = M.component_payloads(name, rec, now_ts)
	return {
		kind = 'device.component.event.state-changed',
		ts = now_ts,
		component = name,
		availability = payloads.component.availability,
		available = payloads.component.available,
		ready = payloads.component.ready,
		health = payloads.component.health,
		reason = payloads.component.reason,
		software = copy(payloads.software),
		update = copy(payloads.update),
		status = copy(payloads.cap_status),
	}
end

return M
