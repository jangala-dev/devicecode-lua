-- services/update/bundled.lua
--
-- Bundled update policy coordinator shape.
--
-- This module performs no blocking artifact or job work inline. It records
-- desired/current policy state, starts scoped probe/import workers, and then
-- starts scoped apply workers when policy asks for durable job creation.

local bundled_probe = require 'services.update.bundled_probe'
local bundled_apply = require 'services.update.bundled_apply'
local model = require 'services.update.model'

local M = {}

local Coordinator = {}
Coordinator.__index = Coordinator

local function copy(v) return model.deep_copy(v) end

local function component_config(cfg, component)
	cfg = cfg or {}
	local by_component = cfg.components or cfg.by_component or {}
	return by_component[component] or cfg[component]
end

local function component_order(cfg)
	local out = {}
	local by_component = (cfg and (cfg.components or cfg.by_component)) or {}
	for component, item in pairs(by_component) do
		if type(component) == 'string' and component ~= '' and type(item) == 'table' then
			out[#out + 1] = component
		end
	end
	table.sort(out)
	return out
end

local function job_policy(item)
	item = item or {}
	local job = copy(item.job or {})
	if job.create_if == nil then
		if item.auto_create ~= nil then
			job.create_if = item.auto_create == true and 'always' or 'never'
		else
			job.create_if = 'image_differs'
		end
	end
	if job.start == nil then job.start = item.auto_start == true and 'auto' or 'manual' end
	if job.commit == nil then job.commit = 'manual' end
	return job
end

local function component_state(snapshot, component)
	if type(snapshot) ~= 'table' then return nil end
	local by_id = snapshot.by_id or snapshot.components
	local rec = type(by_id) == 'table' and by_id[component] or nil
	if type(rec) == 'table' and type(rec.state) == 'table' then return rec.state end
	if type(rec) == 'table' then return rec end
	if snapshot.component == component then return snapshot.state or snapshot end
	return nil
end

local function current_image_id(snapshot, component)
	local state = component_state(snapshot, component)
	local software = type(state) == 'table' and (state.software or (type(state.raw_facts) == 'table' and state.raw_facts.software)) or nil
	local image_id = type(software) == 'table' and software.image_id or nil
	if type(image_id) == 'string' and image_id ~= '' then return image_id end
	return nil
end

local function expected_image_id(desired)
	if type(desired) ~= 'table' then return nil end
	local artifact = desired.artifact or desired.desired or desired
	local image_id = desired.expected_image_id or (type(artifact) == 'table' and artifact.expected_image_id)
	if type(image_id) == 'string' and image_id ~= '' then return image_id end
	return nil
end

function M.new(params)
	params = params or {}
	return setmetatable({
		service_id = params.service_id or 'update',
		generation = params.generation,
		config = copy(params.config or {}),
		probes = {},
		applies = {},
		desired = {},
		state = {},
		last_apply = {},
	}, Coordinator)
end

function Coordinator:enabled()
	return self.config and self.config.enabled == true
end

function Coordinator:components()
	return component_order(self.config)
end

function Coordinator:spec(component)
	return component_config(self.config, component)
end

function Coordinator:needs_probe(component)
	if not self:enabled() then return false end
	local item = self:spec(component)
	return type(item) == 'table'
		and item.source ~= nil
		and self.desired[component] == nil
		and self.probes[component] == nil
		and self.applies[component] == nil
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
	self.state[component] = 'probe_running'
	return handle, nil
end

function Coordinator:start_missing_probes(spec)
	spec = spec or {}
	local started = {}
	if not self:enabled() then return started, nil end
	for _, component in ipairs(self:components()) do
		if self:needs_probe(component) then
			local item = assert(self:spec(component))
			local handle, err = self:start_probe {
				lifetime_scope = spec.lifetime_scope,
				reaper_scope = spec.reaper_scope,
				report_scope = spec.report_scope,
				component = component,
				artifact_store = spec.artifact_store,
				source = item.source,
				done_tx = spec.done_tx,
			}
			if not handle then return nil, err end
			started[#started + 1] = component
		end
	end
	return started, nil
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

function Coordinator:needs_apply(component, opts)
	opts = opts or {}
	if not self:enabled() then return false end
	local item = self:spec(component)
	local policy = job_policy(item)
	local desired = self.desired[component]
	if type(item) ~= 'table' or desired == nil or self.applies[component] ~= nil or self.last_apply[component] ~= nil then
		return false
	end
	if policy.create_if == 'never' then
		self.state[component] = 'create_disabled'
		return false
	end
	if policy.create_if == 'image_differs' then
		local expected = expected_image_id(desired)
		local current = current_image_id(opts.current or opts.components or opts.observer_snapshot, component)
		if expected == nil then
			self.state[component] = 'pending_expected_image'
			return false
		end
		if current == nil then
			self.state[component] = 'pending_current_image'
			return false
		end
		if current == expected then
			self.state[component] = 'already_current'
			return false
		end
	end
	return true
end

function Coordinator:start_apply(spec)
	spec = spec or {}
	local component = assert(spec.component, 'component required')
	if self.applies[component] then return nil, 'apply already running' end
	local item = spec.config or self:spec(component) or {}
	local desired = spec.desired or self.desired[component]
	if desired == nil then return nil, 'desired artifact missing' end
	local apply_spec = copy(item)
	apply_spec.component = apply_spec.component or component
	local handle, err = bundled_apply.start {
		lifetime_scope = assert(spec.lifetime_scope, 'lifetime_scope required'),
		reaper_scope = spec.reaper_scope or spec.lifetime_scope,
		report_scope = spec.report_scope or spec.lifetime_scope,
		service_id = self.service_id,
		generation = self.generation,
		component = component,
		jobs = assert(spec.jobs, 'jobs required'),
		spec = apply_spec,
		desired = desired,
		done_tx = spec.done_tx,
	}
	if not handle then return nil, err end
	self.applies[component] = handle
	self.state[component] = 'apply_running'
	return handle, nil
end

function Coordinator:start_ready_applies(spec)
	spec = spec or {}
	local started = {}
	if not self:enabled() then return started, nil end
	for _, component in ipairs(self:components()) do
		if self:needs_apply(component, spec) then
			local handle, err = self:start_apply {
				lifetime_scope = spec.lifetime_scope,
				reaper_scope = spec.reaper_scope,
				report_scope = spec.report_scope,
				component = component,
				jobs = spec.jobs,
				done_tx = spec.done_tx,
			}
			if not handle then return nil, err end
			started[#started + 1] = component
		end
	end
	return started, nil
end

function Coordinator:handle_apply_done(ev)
	if not ev or ev.kind ~= 'bundled_apply_done' then return false, 'not_apply_done' end
	if ev.generation ~= self.generation then return false, 'stale_generation' end
	self.applies[ev.component] = nil
	self.last_apply[ev.component] = copy(ev)
	if ev.status == 'ok' then
		self.state[ev.component] = 'applied'
	else
		self.state[ev.component] = 'apply_failed'
	end
	return true, nil
end

function Coordinator:snapshot()
	return {
		generation = self.generation,
		enabled = self:enabled(),
		desired = copy(self.desired),
		state = copy(self.state),
		last_apply = copy(self.last_apply),
	}
end

M.Coordinator = Coordinator
return M
