-- services/device/catalogue.lua
--
-- Pure effective component catalogue construction.
-- The catalogue owns no live resources and performs no Ops.

local topics = require 'services.device.topics'
local mcu_schema = require 'services.device.schemas.mcu'
local component_host = require 'services.device.component_host'
local component_mcu = require 'services.device.component_mcu'
local tablex = require 'shared.table'

local M = {}

local copy_array = tablex.array_copy
local copy_value = tablex.deep_copy
local deep_equal = tablex.deep_equal

local function is_array(t)
	return type(t) == 'table' and #t > 0 and tablex.is_array(t)
end


local function component_module_for(id, spec)
	if type(spec) ~= 'table' then spec = {} end
	if type(spec.module) == 'table' then return spec.module end
	if type(spec.module) == 'string' then
		local ok, mod = pcall(require, spec.module)
		if ok and type(mod) == 'table' then return mod end
		local ok2, mod2 = pcall(require, 'services.device.component_' .. spec.module)
		if ok2 and type(mod2) == 'table' then return mod2 end
		local ok3, mod3 = pcall(require, 'services.device.' .. spec.module)
		if ok3 and type(mod3) == 'table' then return mod3 end
		return nil, 'unknown component module: ' .. tostring(spec.module)
	end

	local kind = spec.kind or spec.subtype or spec.class or id
	if kind == 'host' or kind == 'cm5' or spec.class == 'host' then return component_host end
	if kind == 'mcu' or spec.member_class == 'mcu' then return component_mcu end
	return nil, nil
end

local function public_method_name(name)
	name = tostring(name or '')
	return name:gsub('_', '-')
end

local function assert_topic(topic, where)
	if not is_array(topic) then
		error(where .. ' must be a non-empty topic array', 0)
	end
	return copy_array(topic)
end

local function normalise_fact_routes(facts, where)
	local out = {}
	if facts == nil then return out end
	if type(facts) ~= 'table' then error(where .. ': facts must be a table', 0) end

	for fact_name, spec in pairs(facts) do
		if type(fact_name) ~= 'string' or fact_name == '' then
			error(where .. ': fact names must be non-empty strings', 0)
		end

		local topic = spec
		if type(spec) == 'table' and spec.watch_topic ~= nil then
			topic = spec.watch_topic
		end

		out[fact_name] = {
			name = fact_name,
			watch_topic = assert_topic(topic, where .. ': fact ' .. fact_name),
		}
	end

	return out
end

local function normalise_event_routes(events, where)
	local out = {}
	if events == nil then return out end
	if type(events) ~= 'table' then error(where .. ': events must be a table', 0) end

	for event_name, spec in pairs(events) do
		if type(event_name) ~= 'string' or event_name == '' then
			error(where .. ': event names must be non-empty strings', 0)
		end

		local topic = spec
		if type(spec) == 'table' and spec.subscribe_topic ~= nil then
			topic = spec.subscribe_topic
		end

		out[event_name] = {
			name = event_name,
			subscribe_topic = assert_topic(topic, where .. ': event ' .. event_name),
		}
	end

	return out
end

local function opt_target(v, where)
	if v == nil then return nil end
	if type(v) ~= 'string' or v == '' then
		error(where .. ': fabric_stage target must be a non-empty string', 0)
	end
	return v
end

local function opt_pos_int(v, where, default)
	if v == nil then return default end
	local n = tonumber(v)
	if type(n) ~= 'number' or n <= 0 or n % 1 ~= 0 then
		error(where .. ': fabric_stage chunk_size must be a positive integer', 0)
	end
	return n
end

local function normalise_actions(actions, where)
	local out = {}
	if actions == nil then return out end
	if type(actions) ~= 'table' then error(where .. ': actions must be a table', 0) end

	for action_name, spec in pairs(actions) do
		if type(action_name) ~= 'string' or action_name == '' then
			error(where .. ': action names must be non-empty strings', 0)
		end

		local public_name = public_method_name(action_name)

		if type(spec) == 'table' then
			if spec[1] ~= nil and spec.kind == nil and spec.call_topic == nil then
				error(where .. ': action ' .. action_name .. ' must be a table with kind and call_topic', 0)
			end
			local kind = spec.kind or 'rpc'

			if kind == 'rpc' then
				if spec.topic ~= nil then
					error(where .. ': action ' .. action_name .. ' uses deprecated topic; use call_topic', 0)
				end
				if spec.timeout ~= nil then
					error(where .. ': action ' .. action_name .. ' uses deprecated timeout; use timeout_s', 0)
				end
				out[public_name] = {
					name = public_name,
					kind = 'rpc',
					call_topic = assert_topic(spec.call_topic, where .. ': action ' .. action_name .. ' call_topic'),
					timeout = tonumber(spec.timeout_s) or nil,
					dependency = copy_value(spec.dependency),
				}
			elseif kind == 'fabric_stage' then
				if spec.timeout ~= nil then
					error(where .. ': action ' .. action_name .. ' uses deprecated timeout; use timeout_s', 0)
				end

				if spec.receiver ~= nil then
					error(where .. ': action ' .. action_name .. ' uses deprecated receiver; use target', 0)
				end
				local target = opt_target(spec.target, where .. ': action ' .. action_name .. ' target')
				if target == nil then
					error(where .. ': action ' .. action_name .. ' requires fabric_stage target', 0)
				end

				out[public_name] = {
					name = public_name,
					kind = 'fabric_stage',
					link_id = spec.link_id,
					target = target,
					chunk_size = opt_pos_int(spec.chunk_size, where .. ': action ' .. action_name .. ' chunk_size', nil),
					artifact_store = spec.artifact_store or 'main',
					timeout = tonumber(spec.timeout_s) or nil,
					dependency = copy_value(spec.dependency),
				}
			else
				error(where .. ': unsupported action kind for ' .. action_name .. ': ' .. tostring(kind), 0)
			end
		else
			error(where .. ': action ' .. action_name .. ' must be a table with kind and call_topic', 0)
		end
	end

	return out
end

local function empty_state_for_routes(routes)
	local raw, state = {}, {}
	for name in pairs(routes or {}) do
		raw[name] = nil
		state[name] = { seen = false, updated_at = nil }
	end
	return raw, state
end

local function normalise_component(id, spec)
	spec = type(spec) == 'table' and spec or {}
	local where = 'component ' .. tostring(id)
	local mod, mod_err = component_module_for(id, spec)
	if mod_err then error(where .. ': ' .. mod_err, 0) end

	local facts = normalise_fact_routes(spec.facts, where)
	local events = normalise_event_routes(spec.events, where)
	if next(facts) == nil and next(events) == nil then
		error(where .. ': at least one fact or event is required', 0)
	end

	local raw_facts, fact_state = empty_state_for_routes(facts)
	local raw_events, event_state = empty_state_for_routes(events)
	local observe_opts = spec.observe_opts

	return {
		id = id,
		name = id,
		kind = spec.kind or (mod and mod.kind) or spec.subtype or spec.class or id,
		module = mod,
		class = spec.class or ((mod == component_host) and 'host' or 'member'),
		subtype = spec.subtype or (mod and mod.kind) or id,
		role = spec.role or 'member',
		member = spec.member or id,
		member_class = spec.member_class or spec.subtype or spec.class or id,
		link_class = spec.link_class,
		display = copy_value(spec.display or {}),
		present = spec.present ~= false,
		observe_opts = type(observe_opts) == 'table' and copy_value(observe_opts) or {},
		required_facts = copy_array(spec.required_facts),
		availability = copy_value(spec.availability or {}),
		facts = facts,
		events = events,
		actions = normalise_actions(spec.actions, where),
		raw_facts = raw_facts,
		fact_state = fact_state,
		raw_events = raw_events,
		event_state = event_state,
		source_up = false,
		source_err = nil,
	}
end

local function default_components()
	return {
		cm5 = normalise_component('cm5', {
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
				['prepare-update'] = { kind = 'rpc', call_topic = topics.raw_host_cap_rpc('updater', 'updater', 'cm5', 'prepare') },
				['stage-update'] = { kind = 'rpc', call_topic = topics.raw_host_cap_rpc('updater', 'updater', 'cm5', 'stage') },
				['commit-update'] = { kind = 'rpc', call_topic = topics.raw_host_cap_rpc('updater', 'updater', 'cm5', 'commit') },
			},
		}),

		mcu = normalise_component('mcu', {
			class = 'member',
			subtype = 'mcu',
			role = 'controller',
			member = 'mcu',
			required_facts = { 'software', 'updater' },
			facts = mcu_schema.member_fact_topics('mcu'),
			events = mcu_schema.member_event_topics('mcu'),
			actions = {
				['restart'] = { kind = 'rpc', call_topic = topics.raw_member_cap_rpc('mcu', 'control', 'main', 'restart') },
				['prepare-update'] = { kind = 'rpc', call_topic = topics.raw_member_cap_rpc('mcu', 'updater', 'main', 'prepare-update') },
				['stage-update'] = {
					kind = 'fabric_stage',
					target = 'updater/main',
					chunk_size = 2048,
					artifact_store = 'main',
				},
				['commit-update'] = { kind = 'rpc', call_topic = topics.raw_member_cap_rpc('mcu', 'updater', 'main', 'commit-update') },
			},
		}),
	}
end

local function normalise_assembly(raw)
	if raw == nil then return {} end
	if type(raw) ~= 'table' then error('device catalogue assembly must be a table', 0) end
	return copy_value(raw)
end

local function components_from_config(raw)
	if raw == nil then return default_components() end
	if type(raw) ~= 'table' then error('device catalogue config must be a table or nil', 0) end

	local list = raw.components
	if list == nil then
		return default_components()
	end
	if type(list) ~= 'table' then
		error('device catalogue components must be a table', 0)
	end

	local out = {}
	for key, spec in pairs(list) do
		local id = key
		if type(spec) == 'table' and spec.id ~= nil then id = spec.id end
		if type(id) ~= 'string' or id == '' then
			error('device catalogue component id must be a non-empty string', 0)
		end
		out[id] = normalise_component(id, spec)
	end
	return out
end

function M.build(raw, opts)
	opts = opts or {}
	local components = components_from_config(raw)
	return {
		kind = 'device_catalogue',
		schema = raw and raw.schema or nil,
		components = components,
		assembly = normalise_assembly(raw and raw.assembly or nil),
		meta = copy_value((raw and raw.meta) or {}),
	}
end

function M.copy(v)
	return copy_value(v)
end

function M.equal(a, b)
	return deep_equal(a, b)
end

function M.component(catalogue, component_id)
	return catalogue and catalogue.components and catalogue.components[component_id] or nil
end

local PUBLIC_ONLY_COMPONENT_FIELDS = {
	display = true,
	present = true,
}

local PUBLIC_ONLY_CATALOGUE_FIELDS = {
	meta = true,
}

local function material_value(v, seen)
	if type(v) ~= 'table' then return v end
	seen = seen or {}
	if seen[v] then return seen[v] end
	local out = {}
	seen[v] = out
	for k, vv in pairs(v) do
		if k == 'components' and type(vv) == 'table' then
			local comps = {}
			out[k] = comps
			for id, comp in pairs(vv) do
				local c = {}
				comps[id] = c
				for ck, cv in pairs(comp) do
					if not PUBLIC_ONLY_COMPONENT_FIELDS[ck] then
						c[material_value(ck, seen)] = material_value(cv, seen)
					end
				end
			end
		elseif not PUBLIC_ONLY_CATALOGUE_FIELDS[k] then
			out[material_value(k, seen)] = material_value(vv, seen)
		end
	end
	return out
end

function M.material_view(catalogue)
	return material_value(catalogue)
end

function M.materially_equal(a, b)
	return deep_equal(M.material_view(a), M.material_view(b))
end

function M.publicly_equal(a, b)
	return deep_equal(a, b)
end

function M.public_component_ids_changed(a, b)
	local out = {}
	local seen = {}
	local ac = (a and a.components) or {}
	local bc = (b and b.components) or {}

	for id in pairs(ac) do seen[id] = true end
	for id in pairs(bc) do seen[id] = true end

	for id in pairs(seen) do
		if not deep_equal(ac[id], bc[id]) then
			out[#out + 1] = id
		end
	end

	table.sort(out)
	return out
end

function M.public_metadata_changed(a, b)
	return not deep_equal(a, b) and M.materially_equal(a, b)
end

M.public_method_name = public_method_name
M.default_components = default_components

return M
