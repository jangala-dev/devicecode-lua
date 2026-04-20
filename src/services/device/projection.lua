local model = require 'services.device.model'

local M = {}

function M.self_topic()
    return { 'state', 'device', 'self' }
end

function M.component_topic(name)
    return { 'state', 'device', 'component', name }
end

function M.component_software_topic(name)
    return { 'state', 'device', 'component', name, 'software' }
end

function M.component_update_topic(name)
    return { 'state', 'device', 'component', name, 'update' }
end

function M.summary_topic()
    return { 'state', 'device', 'components' }
end

function M.component_view(name, rec, now_ts)
    local status = model.copy_value(rec.raw_status)
    local state = type(status) == 'table' and status.state or nil
    local version = type(status) == 'table' and status.version or nil
    local incarnation = type(status) == 'table' and status.incarnation or nil
    local actions = {}
    for action_name in pairs(rec.operations or {}) do actions[action_name] = true end
    local health = (state == nil and 'unknown') or ((state == 'failed' or state == 'unavailable') and 'degraded' or 'ok')
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
        available = status ~= nil,
        health = health,
        state = state,
        version = version,
        incarnation = incarnation,
        actions = actions,
        facets = {
            software = {
                version = version,
                incarnation = incarnation,
            },
            update = {
                state = state,
            },
        },
        status = status,
        source = {
            member = rec.member,
            member_class = rec.member_class,
            link_class = rec.link_class,
            role = rec.role,
            status = {
                watch_topic = model.copy_array(rec.channels and rec.channels.status and rec.channels.status.watch_topic),
                get_topic = model.copy_array(rec.channels and rec.channels.status and rec.channels.status.get_topic),
            },
        },
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
            health = view.health,
            state = view.state,
            version = view.version,
            incarnation = view.incarnation,
            actions = view.actions,
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
        kind = 'device.self',
        ts = now_ts,
        counts = summary.counts,
        components = summary.components,
    }
end

function M.software_payload(name, rec, now_ts)
    local view = M.component_view(name, rec, now_ts)
    return {
        kind = 'device.component.software',
        ts = now_ts,
        component = name,
        version = view.version,
        incarnation = view.incarnation,
        role = view.role,
        member = view.member,
        member_class = view.member_class,
        link_class = view.link_class,
    }
end

function M.update_payload(name, rec, now_ts)
    local view = M.component_view(name, rec, now_ts)
    return {
        kind = 'device.component.update',
        ts = now_ts,
        component = name,
        state = view.facets.update.state,
        available = view.available,
        health = view.health,
        actions = view.actions,
    }
end

return M
