-- services/device/model.lua
--
-- Device service state and mutation helpers.
--
-- This module owns:
--   * the in-memory device state record
--   * config merge/application
--   * component record normalisation
--   * dirty tracking for retained publication
--
-- It does not own:
--   * observation/provider lifetime
--   * projection/public payload shapes
--   * transport or endpoint policy
--
-- State shape:
--   state = {
--     schema = <config schema id>,
--     components = { [name] = component_record, ... },
--     dirty_components = { [name] = true, ... },
--     summary_dirty = <boolean>,
--   }
--
-- Component record shape:
--   rec = {
--     name, class, subtype, role,
--     member, member_class, link_class,
--     present,
--     provider, provider_opts,
--     channels = {
--       status = {
--         watch_topic = {...}|nil,
--         get_topic = {...}|nil,
--       },
--     },
--     facts = {
--       [fact_name] = {
--         watch_topic = {...}|nil,
--       },
--     },
--     operations = {
--       [action_name] = {
--         name = <string>,
--         call_topic = {...},
--       },
--     },
--     raw_status = <last raw status>|nil,
--     raw_facts = { [fact_name] = payload|nil, ... },
--     fact_state = { [fact_name] = { seen = <boolean>, updated_at = <number|nil> }, ... },
--     source_up = <boolean>,
--     source_err = <string|nil>,
--   }

local M = {}

----------------------------------------------------------------------
-- Copy helpers
----------------------------------------------------------------------

local function copy_array(t)
	local out = {}
	if type(t) ~= 'table' then
		return out
	end
	for i = 1, #t do
		out[i] = t[i]
	end
	return out
end

local function copy_value(v, seen)
	if type(v) ~= 'table' then
		return v
	end

	seen = seen or {}
	if seen[v] then
		return seen[v]
	end

	local out = {}
	seen[v] = out
	for k, vv in pairs(v) do
		out[copy_value(k, seen)] = copy_value(vv, seen)
	end
	return out
end

M.copy_array = copy_array
M.copy_value = copy_value

----------------------------------------------------------------------
-- Component normalisation
----------------------------------------------------------------------

local function normalize_action_routes(actions)
	local out = {}
	if type(actions) ~= 'table' then
		return out
	end

	for action_name, topic in pairs(actions) do
		if type(action_name) == 'string' and type(topic) == 'table' then
			out[action_name] = {
				name = action_name,
				call_topic = copy_array(topic),
			}
		end
	end

	return out
end

local function normalize_fact_routes(facts)
	local out = {}
	if type(facts) ~= 'table' then
		return out
	end

	for fact_name, topic in pairs(facts) do
		if type(fact_name) == 'string' and type(topic) == 'table' then
			out[fact_name] = {
				name = fact_name,
				watch_topic = copy_array(topic),
			}
		end
	end

	return out
end

local function new_fact_state(facts)
	local raw_facts = {}
	local fact_state = {}
	for fact_name in pairs(facts or {}) do
		raw_facts[fact_name] = nil
		fact_state[fact_name] = { seen = false, updated_at = nil }
	end
	return raw_facts, fact_state
end

local function default_provider_for(spec)
	if type(spec.provider) == 'string' and spec.provider ~= '' then
		return spec.provider
	end
	if type(spec.facts) == 'table' and next(spec.facts) ~= nil then
		return 'fact_watch'
	end
	return 'status_watch'
end

local function normalize_component(name, spec)
	spec = type(spec) == 'table' and spec or {}
	local facts = normalize_fact_routes(spec.facts)
	local raw_facts, fact_state = new_fact_state(facts)

	return {
		name = name,
		class = spec.class or 'member',
		subtype = spec.subtype or name,
		role = spec.role or 'member',
		member = spec.member or name,
		member_class = spec.member_class or spec.subtype or spec.class or name,
		link_class = spec.link_class or nil,
		present = spec.present ~= false,

		provider = default_provider_for(spec),
		provider_opts = type(spec.provider_opts) == 'table' and copy_value(spec.provider_opts) or {},

		channels = {
			status = {
				watch_topic = type(spec.status_topic) == 'table' and copy_array(spec.status_topic) or nil,
				get_topic = type(spec.get_topic) == 'table' and copy_array(spec.get_topic) or nil,
			},
		},
		facts = facts,

		operations = normalize_action_routes(spec.actions),

		raw_status = nil,
		raw_facts = raw_facts,
		fact_state = fact_state,
		source_up = false,
		source_err = nil,
	}
end

local function has_facts(rec)
	return type(rec) == 'table' and type(rec.facts) == 'table' and next(rec.facts) ~= nil
end

M.has_facts = has_facts

----------------------------------------------------------------------
-- Defaults
----------------------------------------------------------------------

local function default_components()
	return {
		cm5 = normalize_component('cm5', {
			class = 'host',
			subtype = 'cm5',
			role = 'primary',
			member = 'local',

			facts = {
				software = { 'cap', 'updater', 'cm5', 'state', 'software' },
				updater = { 'cap', 'updater', 'cm5', 'state', 'updater' },
				health = { 'cap', 'updater', 'cm5', 'state', 'health' },
			},

			actions = {
				prepare_update = { 'cap', 'updater', 'cm5', 'rpc', 'prepare' },
				stage_update = { 'cap', 'updater', 'cm5', 'rpc', 'stage' },
				commit_update = { 'cap', 'updater', 'cm5', 'rpc', 'commit' },
			},
		}),
	}
end

----------------------------------------------------------------------
-- State construction
----------------------------------------------------------------------

function M.new_state(schema)
	return {
		schema = schema,
		components = default_components(),
		dirty_components = {},
		summary_dirty = true,
	}
end

----------------------------------------------------------------------
-- Config merge and application
----------------------------------------------------------------------

local function apply_component_overrides(base, spec)
	if type(spec.class) == 'string' and spec.class ~= '' then
		base.class = spec.class
	end
	if type(spec.subtype) == 'string' and spec.subtype ~= '' then
		base.subtype = spec.subtype
	end
	if type(spec.role) == 'string' and spec.role ~= '' then
		base.role = spec.role
	end
	if type(spec.member) == 'string' and spec.member ~= '' then
		base.member = spec.member
	end
	if type(spec.member_class) == 'string' and spec.member_class ~= '' then
		base.member_class = spec.member_class
	end
	if type(spec.link_class) == 'string' and spec.link_class ~= '' then
		base.link_class = spec.link_class
	end

	if spec.present ~= nil then
		base.present = spec.present ~= false
	end

	if type(spec.provider) == 'string' and spec.provider ~= '' then
		base.provider = spec.provider
	elseif type(spec.facts) == 'table' and next(spec.facts) ~= nil then
		base.provider = 'mcu_split_watch'
	end
	if type(spec.provider_opts) == 'table' then
		base.provider_opts = copy_value(spec.provider_opts)
	end

	if type(spec.status_topic) == 'table' then
		base.channels.status.watch_topic = copy_array(spec.status_topic)
	end
	if type(spec.get_topic) == 'table' then
		base.channels.status.get_topic = copy_array(spec.get_topic)
	end

	if type(spec.facts) == 'table' then
		base.facts = normalize_fact_routes(spec.facts)
		base.raw_facts, base.fact_state = new_fact_state(base.facts)
	end

	if type(spec.actions) == 'table' then
		base.operations = normalize_action_routes(spec.actions)
	end

	-- Configuration redefines the observation plan. Live/source state is reset
	-- and will be repopulated by observers.
	base.raw_status = nil
	if not has_facts(base) then
		base.raw_facts, base.fact_state = {}, {}
	end
	base.source_up = false
	base.source_err = nil

	return base
end

function M.merge_components(cfg, schema)
	local out = default_components()

	if type(cfg) ~= 'table' then
		return out
	end
	if cfg.schema ~= nil and cfg.schema ~= schema then
		return out
	end

	local comps = cfg.components or {}
	if type(comps) ~= 'table' then
		return out
	end

	for name, spec in pairs(comps) do
		if type(name) == 'string' and type(spec) == 'table' then
			local base = out[name] or normalize_component(name, {})
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

----------------------------------------------------------------------
-- Observation mutation
----------------------------------------------------------------------

function M.note_status(state, name, status)
	local rec = state.components[name]
	if not rec then
		return nil
	end

	rec.raw_status = status
	rec.source_up = true
	rec.source_err = nil

	state.dirty_components[name] = true
	state.summary_dirty = true
	return rec
end

function M.note_fact(state, name, fact_name, payload, updated_at)
	local rec = state.components[name]
	if not rec or not has_facts(rec) or type(fact_name) ~= 'string' or fact_name == '' then
		return nil
	end

	rec.raw_facts[fact_name] = payload
	rec.fact_state[fact_name] = rec.fact_state[fact_name] or { seen = false, updated_at = nil }
	rec.fact_state[fact_name].seen = true
	rec.fact_state[fact_name].updated_at = updated_at or rec.fact_state[fact_name].updated_at
	rec.source_up = true
	rec.source_err = nil

	state.dirty_components[name] = true
	state.summary_dirty = true
	return rec
end

function M.note_source_down(state, name, reason)
	local rec = state.components[name]
	if not rec then
		return nil
	end

	if not has_facts(rec) then
		rec.raw_status = { state = 'unavailable', err = reason }
	end
	rec.source_up = false
	rec.source_err = reason

	state.dirty_components[name] = true
	state.summary_dirty = true
	return rec
end

----------------------------------------------------------------------
-- Dirty tracking helpers
----------------------------------------------------------------------

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
