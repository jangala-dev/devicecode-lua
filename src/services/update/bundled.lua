-- services/update/bundled.lua
--
-- Bundled update policy coordinator shape.
--
-- This module deliberately performs no artifact probing inline. It records
-- desired/current policy state and starts bundled_probe scoped work when a
-- probe is needed.

local bundled_probe = require 'services.update.bundled_probe'
local model = require 'services.update.model'

local M = {}

local Coordinator = {}
Coordinator.__index = Coordinator

local function copy(v) return model.deep_copy(v) end

function M.new(params)
	params = params or {}
	return setmetatable({
		service_id = params.service_id or 'update',
		generation = params.generation,
		config = copy(params.config or {}),
		probes = {},
		desired = {},
		state = {},
	}, Coordinator)
end

function Coordinator:needs_probe(component)
	local cfg = self.config or {}
	local by_component = cfg.components or cfg.by_component or {}
	local item = by_component[component] or cfg[component]
	return type(item) == 'table' and item.source ~= nil and self.desired[component] == nil
end

function Coordinator:start_probe(spec)
	spec = spec or {}
	local component = assert(spec.component, 'component required')
	if self.probes[component] then return nil, 'probe already running' end
	local handle, err = bundled_probe.start {
		lifetime_scope = assert(spec.lifetime_scope, 'lifetime_scope required'),
		reaper_scope = spec.reaper_scope or spec.lifetime_scope,
		report_scope = spec.report_scope or spec.lifetime_scope,
		service_id = self.service_id,
		generation = self.generation,
		component = component,
		artifact_store = assert(spec.artifact_store, 'artifact_store required'),
		source = assert(spec.source, 'source required'),
		done_tx = spec.done_tx,
	}
	if not handle then return nil, err end
	self.probes[component] = handle
	return handle, nil
end

function Coordinator:handle_probe_done(ev)
	if not ev or ev.kind ~= 'bundled_probe_done' then return false, 'not_probe_done' end
	if ev.generation ~= self.generation then return false, 'stale_generation' end
	self.probes[ev.component] = nil
	if ev.status == 'ok' then
		self.desired[ev.component] = copy(ev.result and ev.result.desired or ev.result)
		self.state[ev.component] = 'desired_known'
	else
		self.state[ev.component] = 'probe_failed'
	end
	return true, nil
end

function Coordinator:snapshot()
	return {
		generation = self.generation,
		desired = copy(self.desired),
		state = copy(self.state),
	}
end

M.Coordinator = Coordinator
return M
