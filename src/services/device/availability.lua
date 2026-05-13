-- services/device/availability.lua
-- Pure availability and health policy.
--
-- This module consumes only catalogue/model snapshot data.  It performs no Ops,
-- owns no resources, and has no service-side effects.

local tablex = require 'shared.table'

local M = {}

local copy_value = tablex.deep_copy

local function seen_any(states)
	if type(states) ~= 'table' then return false end
	for _, meta in pairs(states) do
		if type(meta) == 'table' and meta.seen == true then return true end
	end
	return false
end

local table_or_empty = tablex.table_or_empty

local function normalise_policy(rec)
	local p = table_or_empty(rec and rec.availability)
	return {
		missing_required = p.missing_required or 'unavailable',
		malformed_required = p.malformed_required or 'degraded',
		source_stale = p.source_stale or 'degraded',
		source_down = p.source_down or 'unavailable',
		no_observation = p.no_observation or 'unknown',
	}
end

local function status(availability, health, reason, details)
	local available = availability == 'available' or availability == 'degraded'
	return {
		availability = availability,
		available = available,
		ready = availability == 'available',
		health = health or (availability == 'available' and 'ok' or 'unknown'),
		reason = reason,
		details = details or {},
	}
end

local function set_status(base, fields)
	fields = fields or {}
	local out = copy_value(base or {})
	for k, v in pairs(fields) do out[k] = v end
	if out.availability == nil then
		out.availability = out.available and (out.ready and 'available' or 'degraded') or 'unknown'
	end
	out.available = out.availability == 'available' or out.availability == 'degraded'
	out.ready = out.availability == 'available'
	return out
end

function M.any_observation_seen(rec)
	if type(rec) ~= 'table' then return false end
	return seen_any(rec.fact_state) or seen_any(rec.event_state)
end

function M.required_facts_ready(rec, required)
	if type(required) ~= 'table' or #required == 0 then
		return M.any_observation_seen(rec)
	end

	local fact_state = type(rec) == 'table' and rec.fact_state or nil
	for i = 1, #required do
		local meta = fact_state and fact_state[required[i]] or nil
		if not (type(meta) == 'table' and meta.seen == true) then
			return false, required[i]
		end
	end
	return true, nil
end

local function health_from_fact(raw_health)
	if raw_health == nil then return nil, nil end
	if type(raw_health) == 'string' then
		local h = raw_health:lower()
		if h == 'ok' then return 'ok', nil end
		if h == 'degraded' then return 'warning', 'health_warning' end
		if h == 'failed' then return 'fault', 'health_fault' end
		return raw_health, nil
	end
	if type(raw_health) == 'table' then
		if raw_health.state ~= nil then return health_from_fact(tostring(raw_health.state)) end
	end
	return nil, nil
end

local function has_only_events(rec)
	return type(rec) == 'table'
		and type(rec.events) == 'table' and next(rec.events) ~= nil
		and not (type(rec.facts) == 'table' and next(rec.facts) ~= nil)
end

local function base_component_status(rec)
	if type(rec) ~= 'table' then
		return status('unknown', 'unknown', 'unknown_component')
	end

	local policy = normalise_policy(rec)
	local details = {}
	local source_err = rec.source_err
	local source_up = rec.source_up == true
	local seen = M.any_observation_seen(rec)

	if source_err ~= nil then
		local reason = tostring(source_err)
		if reason == 'stale' then
			return status(policy.source_stale, 'warning', 'source_stale', { source_reason = reason })
		end
		return status(policy.source_down, 'unknown', reason, { source_reason = reason })
	end

	if not source_up then
		if seen then
			return status('degraded', 'warning', 'source_not_confirmed')
		end
		if has_only_events(rec) then
			return status('available', 'ok', nil)
		end
		return status(policy.no_observation, 'unknown', 'no_observation')
	end

	local ready, missing = M.required_facts_ready(rec, rec.required_facts)
	if not ready then
		details.missing_fact = missing
		return status(policy.missing_required, 'unknown', 'missing_required_fact', details)
	end

	local health, health_reason = health_from_fact(rec.raw_facts and rec.raw_facts.health or nil)
	if health == 'fault' then
		return status('unavailable', 'fault', health_reason or 'health_fault')
	elseif health == 'warning' or health == 'degraded' then
		return status('degraded', 'warning', health_reason or 'health_warning')
	end

	if ready or has_only_events(rec) then
		return status('available', health or 'ok', nil)
	end

	return status('degraded', health or 'warning', 'not_ready')
end

--- Compute public availability for a component snapshot/catalogue entry.
--- Component modules may refine the generic status by exposing:
---   availability(base_status, rec) -> status_table
function M.component_status(rec)
	local base = base_component_status(rec)
	local mod = type(rec) == 'table' and rec.module or nil
	if type(mod) == 'table' and type(mod.availability) == 'function' then
		local ok, refined = pcall(mod.availability, base, rec)
		if ok and type(refined) == 'table' then
			return set_status(base, refined)
		elseif not ok then
			return status('degraded', 'warning', 'availability_refine_failed', { error = tostring(refined) })
		end
	end
	return set_status(base)
end

M.copy_value = copy_value

return M
