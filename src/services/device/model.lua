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
    for k, vv in pairs(v) do out[copy_value(k, seen)] = copy_value(vv, seen) end
    return out
end

M.copy_array = copy_array
M.copy_value = copy_value

local function normalize_action_routes(actions)
    local out = {}
    if type(actions) ~= 'table' then return out end
    for action_name, topic in pairs(actions) do
        if type(action_name) == 'string' and type(topic) == 'table' then
            out[action_name] = {
                name = action_name,
                kind = action_name:match('_update$') and 'update' or 'call',
                call_topic = copy_array(topic),
            }
        end
    end
    return out
end

local function normalize_component(name, spec)
    spec = type(spec) == 'table' and spec or {}
    local rec = {
        name = name,
        class = spec.class or 'member',
        subtype = spec.subtype or name,
        role = spec.role or 'member',
        member = spec.member or name,
        member_class = spec.member_class or spec.subtype or spec.class or name,
        link_class = spec.link_class or nil,
        present = spec.present ~= false,
        channels = {
            status = {
                watch_topic = type(spec.status_topic) == 'table' and copy_array(spec.status_topic) or nil,
                get_topic = type(spec.get_topic) == 'table' and copy_array(spec.get_topic) or nil,
            },
        },
        operations = normalize_action_routes(spec.actions),
        raw_status = nil,
        source_up = false,
        source_err = nil,
    }
    return rec
end

local function default_components()
    return {
        cm5 = normalize_component('cm5', {
            class = 'host',
            subtype = 'cm5',
            role = 'primary',
            member = 'local',
            status_topic = { 'cap', 'updater', 'cm5', 'state', 'status' },
            get_topic = { 'cap', 'updater', 'cm5', 'rpc', 'status' },
            actions = {
                prepare_update = { 'cap', 'updater', 'cm5', 'rpc', 'prepare' },
                stage_update = { 'cap', 'updater', 'cm5', 'rpc', 'stage' },
                commit_update = { 'cap', 'updater', 'cm5', 'rpc', 'commit' },
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

function M.merge_components(cfg, schema)
    local out = default_components()
    if type(cfg) ~= 'table' then return out end
    if cfg.schema ~= nil and cfg.schema ~= schema then return out end
    local comps = cfg.components or {}
    if type(comps) ~= 'table' then return out end
    for name, spec in pairs(comps) do
        if type(name) == 'string' and type(spec) == 'table' then
            local base = out[name] or normalize_component(name, {})
            if type(spec.class) == 'string' and spec.class ~= '' then base.class = spec.class end
            if type(spec.subtype) == 'string' and spec.subtype ~= '' then base.subtype = spec.subtype end
            if type(spec.role) == 'string' and spec.role ~= '' then base.role = spec.role end
            if type(spec.member) == 'string' and spec.member ~= '' then base.member = spec.member end
            if type(spec.member_class) == 'string' and spec.member_class ~= '' then base.member_class = spec.member_class end
            if type(spec.link_class) == 'string' and spec.link_class ~= '' then base.link_class = spec.link_class end
            if spec.present ~= nil then base.present = spec.present ~= false end
            if type(spec.status_topic) == 'table' then base.channels.status.watch_topic = copy_array(spec.status_topic) end
            if type(spec.get_topic) == 'table' then base.channels.status.get_topic = copy_array(spec.get_topic) end
            if type(spec.actions) == 'table' then base.operations = normalize_action_routes(spec.actions) end
            base.raw_status = nil
            base.source_up = false
            base.source_err = nil
            out[name] = base
        end
    end
    return out
end

function M.apply_cfg(state, payload)
    local data = payload and (payload.data or payload) or nil
    state.components = M.merge_components(data, state.schema)
    for name in pairs(state.components) do state.dirty_components[name] = true end
    state.summary_dirty = true
end

function M.note_status(state, name, status)
    local rec = state.components[name]
    if not rec then return nil end
    rec.raw_status = status
    rec.source_up = true
    rec.source_err = nil
    state.dirty_components[name] = true
    state.summary_dirty = true
    return rec
end

function M.note_source_down(state, name, reason)
    local rec = state.components[name]
    if not rec then return nil end
    rec.raw_status = { state = 'unavailable', err = reason }
    rec.source_up = false
    rec.source_err = reason
    state.dirty_components[name] = true
    state.summary_dirty = true
    return rec
end

function M.mark_all_dirty(state)
    for name in pairs(state.components) do state.dirty_components[name] = true end
    state.summary_dirty = true
end

function M.clear_component_dirty(state, name)
    state.dirty_components[name] = nil
end

function M.set_summary_clean(state)
    state.summary_dirty = false
end

return M
