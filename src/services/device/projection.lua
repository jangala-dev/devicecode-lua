local model = require 'services.device.model'
local normalize = require 'services.device.normalize'

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

local function copy(t)
    return model.copy_value(t)
end

function M.component_view(name, rec, now_ts)
    local base = normalize.normalize_component_status(rec, rec.raw_status)

    local actions = {}
    for action_name in pairs(rec.operations or {}) do actions[action_name] = true end
    local capabilities = copy(base.capabilities or {})
    if next(actions) ~= nil then capabilities.update = true end
    local available = (rec.source_up == true) and (base.available ~= false)
    local ready = available and (base.ready ~= false)
    local updater_state = type(base.updater) == 'table' and base.updater.state or nil
    local health = base.health
    if health == nil then
        health = (not available and 'unknown') or ((updater_state == 'failed' or updater_state == 'unavailable') and 'degraded' or 'ok')
    end
    local source = copy(base.source or {})
    source.member = rec.member
    source.member_class = rec.member_class
    source.link_class = rec.link_class
    source.role = rec.role
    source.kind = source.kind or ((rec.class == 'host') and 'host' or 'member')
    source.status = {
        watch_topic = model.copy_array(rec.channels and rec.channels.status and rec.channels.status.watch_topic),
        get_topic = model.copy_array(rec.channels and rec.channels.status and rec.channels.status.get_topic),
    }
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
        capabilities = capabilities,
        software = copy(base.software),
        updater = copy(base.updater),
        source = source,
        raw = base.raw,
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
    local sw = copy(view.software)
    sw.kind = 'device.component.software'
    sw.ts = now_ts
    sw.component = name
    sw.role = view.role
    sw.member = view.member
    sw.member_class = view.member_class
    sw.link_class = view.link_class
    return sw
end

function M.update_payload(name, rec, now_ts)
    local view = M.component_view(name, rec, now_ts)
    local upd = copy(view.updater)
    upd.kind = 'device.component.update'
    upd.ts = now_ts
    upd.component = name
    upd.available = view.available
    upd.health = view.health
    upd.actions = view.actions
    return upd
end

return M
