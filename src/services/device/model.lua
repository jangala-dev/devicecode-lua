-- services/device/model.lua
--
-- Pulse-backed public Device state model.
-- The model is non-suspending: it stores snapshots, applies observations, and
-- exposes changed_op(version). It does not publish, call HAL, or spawn work.

local pulse = require 'fibers.pulse'
local availability = require 'services.device.availability'
local tablex = require 'shared.table'

local M = {}

local copy_value = tablex.deep_copy
local deep_equal = tablex.deep_equal

local function now_or_nil()
	local ok, fibers = pcall(require, 'fibers')
	if ok and fibers and type(fibers.now) == 'function' then
		return fibers.now()
	end
	return nil
end

local function empty_snapshot()
	return {
		generation = 0,
		catalogue = nil,
		components = {},
		dependencies = {},
	}
end


local function recompute_component_status(rec)
	if type(rec) ~= 'table' then return rec end
	rec.status = availability.component_status(rec)
	rec.available = rec.status.available
	rec.ready = rec.status.ready
	rec.health = rec.status.health
	rec.reason = rec.status.reason
	return rec
end

local function copy_component_template(component)
	local rec = copy_value(component)
	rec.raw_facts = copy_value(rec.raw_facts or {})
	rec.fact_state = copy_value(rec.fact_state or {})
	rec.raw_events = copy_value(rec.raw_events or {})
	rec.event_state = copy_value(rec.event_state or {})
	rec.source_up = rec.source_up == true
	rec.source_err = rec.source_err
	rec.last_action = copy_value(rec.last_action)
	return recompute_component_status(rec)
end

local function apply_if_changed(self, next_snapshot)
	if self._closed then
		return nil, self._closed_reason or 'terminated'
	end

	if deep_equal(self._snapshot, next_snapshot) then
		return false, self:version()
	end

	self._snapshot = copy_value(next_snapshot)
	local v = self._pulse:signal()
	return true, v
end

local DeviceModel = {}
DeviceModel.__index = DeviceModel

function DeviceModel:version()
	return self._pulse:version()
end

function DeviceModel:is_terminated()
	return self._closed
end

function DeviceModel:why()
	return self._closed_reason
end

function DeviceModel:snapshot()
	return copy_value(self._snapshot)
end

function DeviceModel:component_snapshot(component_id)
	local rec = self._snapshot.components and self._snapshot.components[component_id] or nil
	return copy_value(rec)
end

function DeviceModel:set_snapshot(snapshot)
	return apply_if_changed(self, copy_value(snapshot or empty_snapshot()))
end

function DeviceModel:apply_catalogue(generation, catalogue)
	local next_snapshot = empty_snapshot()
	next_snapshot.generation = generation or 0
	next_snapshot.catalogue = copy_value(catalogue)

	for id, component in pairs((catalogue and catalogue.components) or {}) do
		next_snapshot.components[id] = copy_component_template(component)
	end

	return apply_if_changed(self, next_snapshot)
end


function DeviceModel:update_catalogue_metadata(generation, catalogue)
	local snap = self:snapshot()
	if snap.generation ~= generation then
		return false, self:version(), 'stale_generation'
	end

	catalogue = catalogue or {}
	snap.catalogue = copy_value(catalogue)

	for id, component in pairs((catalogue and catalogue.components) or {}) do
		local rec = snap.components[id]
		if rec then
			-- Public metadata refresh only. Material catalogue changes are handled by
			-- starting a new generation, so live observation state is intentionally
			-- preserved here.
			rec.display = copy_value(component.display or {})
			rec.present = component.present ~= false
			rec.availability = copy_value(component.availability or rec.availability or {})
			recompute_component_status(rec)
		end
	end

	return apply_if_changed(self, snap)
end


function DeviceModel:update_dependencies(generation, dependencies)
	local snap = self:snapshot()
	if snap.generation ~= generation then
		return false, self:version(), 'stale_generation'
	end
	snap.dependencies = copy_value(dependencies or {})
	return apply_if_changed(self, snap)
end

function DeviceModel:apply_observation(generation, observation)
	local snap = self:snapshot()
	if snap.generation ~= generation then
		return false, self:version(), 'stale_generation'
	end

	observation = observation or {}
	local component_id = observation.component
	local rec = component_id and snap.components[component_id] or nil
	if not rec then
		return false, self:version(), 'unknown_component'
	end

	local tag = observation.tag
	local ts = observation.at or observation.ts or now_or_nil()

	if tag == 'fact_retained' or tag == 'fact_changed' then
		local fact = observation.fact
		if type(fact) ~= 'string' or fact == '' then
			return false, self:version(), 'missing_fact'
		end
		rec.raw_facts[fact] = copy_value(observation.payload)
		rec.fact_state[fact] = rec.fact_state[fact] or {}
		rec.fact_state[fact].seen = observation.payload ~= nil
		rec.fact_state[fact].updated_at = ts
		rec.source_up = true
		rec.source_err = nil
	elseif tag == 'fact_unretained' then
		local fact = observation.fact
		if type(fact) ~= 'string' or fact == '' then
			return false, self:version(), 'missing_fact'
		end
		rec.raw_facts[fact] = nil
		rec.fact_state[fact] = rec.fact_state[fact] or {}
		rec.fact_state[fact].seen = false
		rec.fact_state[fact].updated_at = ts
	elseif tag == 'event' or tag == 'event_seen' then
		local event = observation.event
		if type(event) ~= 'string' or event == '' then
			return false, self:version(), 'missing_event'
		end
		rec.raw_events[event] = copy_value(observation.payload)
		rec.event_state[event] = rec.event_state[event] or { count = 0 }
		rec.event_state[event].seen = true
		rec.event_state[event].updated_at = ts
		rec.event_state[event].count = (tonumber(rec.event_state[event].count) or 0) + 1
		rec.source_up = true
		rec.source_err = nil
	elseif tag == 'source_down' then
		rec.source_up = false
		rec.source_err = observation.reason or 'source_down'
	else
		return false, self:version(), 'unknown_observation_tag'
	end

	recompute_component_status(rec)
	return apply_if_changed(self, snap)
end

function DeviceModel:apply_source_down(generation, component_id, reason)
	return self:apply_observation(generation, {
		component = component_id,
		tag = 'source_down',
		reason = reason or 'source_down',
	})
end

function DeviceModel:apply_action_result(generation, action_result)
	local snap = self:snapshot()
	if snap.generation ~= generation then
		return false, self:version(), 'stale_generation'
	end

	action_result = action_result or {}
	local component_id = action_result.component
	local rec = component_id and snap.components[component_id] or nil
	if not rec then
		return false, self:version(), 'unknown_component'
	end

	rec.last_action = copy_value(action_result)
	recompute_component_status(rec)
	return apply_if_changed(self, snap)
end

function DeviceModel:changed_op(seen)
	if type(seen) ~= 'number' or seen < 0 or seen % 1 ~= 0 then
		error('device.model.changed_op: seen must be a non-negative integer', 2)
	end

	return self._pulse:changed_op(seen):wrap(function (version, reason)
		if version == nil then
			return nil, nil, reason or self._closed_reason or 'terminated'
		end
		return version, self:snapshot(), nil
	end)
end

function DeviceModel:terminate(reason)
	if self._closed then
		if self._closed_reason == nil and reason ~= nil then
			self._closed_reason = reason
		end
		return true
	end

	self._closed = true
	self._closed_reason = reason or 'terminated'
	self._pulse:close(self._closed_reason)
	return true
end

local function new(initial)
	return setmetatable({
		_snapshot = copy_value(initial or empty_snapshot()),
		_pulse = pulse.new(0),
		_closed = false,
		_closed_reason = nil,
	}, DeviceModel)
end

M.new = new
M.DeviceModel = DeviceModel
M.copy_value = copy_value
M.deep_equal = deep_equal

return M
