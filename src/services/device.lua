local fibers = require 'fibers'
local base   = require 'devicecode.service_base'
local safe   = require 'coxpcall'

local M = {}
local SCHEMA = 'devicecode.config/device/1'

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

local function retain_best_effort(conn, topic, payload)
    safe.pcall(function() conn:retain(topic, payload) end)
end

local function unretain_best_effort(conn, topic)
    safe.pcall(function() conn:unretain(topic) end)
end

local function component_topic(name)
    return { 'state', 'device', 'component', name }
end

local function summary_topic()
    return { 'state', 'device', 'components' }
end

local function default_components()
    return {
        cm5 = {
            name = 'cm5',
            class = 'host',
            subtype = 'cm5',
            status_topic = { 'cap', 'updater', 'cm5', 'state', 'status' },
            get_topic = { 'cap', 'updater', 'cm5', 'rpc', 'status' },
            actions = {
                prepare_update = { 'cap', 'updater', 'cm5', 'rpc', 'prepare' },
                stage_update = { 'cap', 'updater', 'cm5', 'rpc', 'stage' },
                commit_update = { 'cap', 'updater', 'cm5', 'rpc', 'commit' },
            },
        },
    }
end

local function merge_components(cfg)
    local out = default_components()
    if type(cfg) ~= 'table' then return out end
    if cfg.schema ~= nil and cfg.schema ~= SCHEMA then return out end
    local comps = cfg.components or {}
    if type(comps) ~= 'table' then return out end
    for name, spec in pairs(comps) do
        if type(name) == 'string' and type(spec) == 'table' then
            local cur = out[name] or {
                name = name,
                class = 'member',
                subtype = name,
                actions = {},
            }
            if type(spec.class) == 'string' and spec.class ~= '' then cur.class = spec.class end
            if type(spec.subtype) == 'string' and spec.subtype ~= '' then cur.subtype = spec.subtype end
            if type(spec.status_topic) == 'table' then cur.status_topic = copy_array(spec.status_topic) end
            if type(spec.get_topic) == 'table' then cur.get_topic = copy_array(spec.get_topic) end
            if type(spec.actions) == 'table' then
                cur.actions = {}
                for action_name, topic in pairs(spec.actions) do
                    if type(action_name) == 'string' and type(topic) == 'table' then
                        cur.actions[action_name] = copy_array(topic)
                    end
                end
            end
            out[name] = cur
        end
    end
    return out
end

local function component_view(name, rec, now_ts)
    local status = copy_value(rec.status)
    local state = type(status) == 'table' and (status.state or status.status or status.kind) or nil
    local version = type(status) == 'table' and (status.version or status.fw_version) or nil
    local incarnation = type(status) == 'table' and (status.incarnation or status.generation) or nil
    local actions = {}
    for action_name in pairs(rec.actions or {}) do actions[action_name] = true end
    return {
        kind = 'device.component',
        ts = now_ts,
        component = name,
        class = rec.class,
        subtype = rec.subtype,
        present = rec.present ~= false,
        available = status ~= nil,
        state = state,
        version = version,
        incarnation = incarnation,
        actions = actions,
        status = status,
        source = {
            status_topic = copy_array(rec.status_topic),
            get_topic = copy_array(rec.get_topic),
        },
    }
end

local function publish_component_state(conn, svc, name, rec)
    retain_best_effort(conn, component_topic(name), component_view(name, rec, svc:now()))
end

local function publish_summary(conn, svc, components)
    local items = {}
    for name, rec in pairs(components) do
        local view = component_view(name, rec, svc:now())
        items[name] = {
            class = view.class,
            subtype = view.subtype,
            present = view.present,
            available = view.available,
            state = view.state,
            version = view.version,
            incarnation = view.incarnation,
            actions = view.actions,
        }
    end
    retain_best_effort(conn, summary_topic(), {
        kind = 'device.components',
        ts = svc:now(),
        components = items,
    })
end

function M.start(conn, opts)
    opts = opts or {}
    local svc = base.new(conn, { name = opts.name or 'device', env = opts.env })
    svc:status('starting')
    svc:spawn_heartbeat((opts.heartbeat_s or 30.0), 'tick')

    local cfg_watch = conn:watch_retained({ 'cfg', 'device' }, { replay = true, queue_len = 8, full = 'drop_oldest' })
    local status_subs = {}
    local components = merge_components(nil)

    local function close_status_subs()
        for _, sub in pairs(status_subs) do
            pcall(function() sub:unsubscribe() end)
        end
        status_subs = {}
    end

    local function seed_component_status(name, rec)
        if type(rec.get_topic) == 'table' then
            local value = nil
            local ok = safe.pcall(function()
                value = conn:call(rec.get_topic, {}, { timeout = 0.5 })
            end)
            if ok and value ~= nil then
                rec.status = value
            end
        end
    end

    local function rebuild_status_subs()
        close_status_subs()
        for name, rec in pairs(components) do
            if type(rec.status_topic) == 'table' then
                status_subs[name] = conn:subscribe(rec.status_topic, { queue_len = 16, full = 'drop_oldest' })
            end
            seed_component_status(name, rec)
            publish_component_state(conn, svc, name, rec)
        end
        publish_summary(conn, svc, components)
    end

    local function apply_cfg(payload)
        components = merge_components(payload and payload.data or payload)
        for name, rec in pairs(components) do
            rec.name = name
            rec.status = nil
            rec.actions = rec.actions or {}
            rec.present = rec.present ~= false
        end
        rebuild_status_subs()
    end

    apply_cfg(nil)

    local get_ep = conn:bind({ 'cmd', 'device', 'component', 'get' }, { queue_len = 32 })
    local do_ep = conn:bind({ 'cmd', 'device', 'component', 'do' }, { queue_len = 32 })

    svc:status('running')

    fibers.current_scope():finally(function()
        close_status_subs()
        pcall(function() get_ep:unbind() end)
        pcall(function() do_ep:unbind() end)
        for name, _ in pairs(components) do
            unretain_best_effort(conn, component_topic(name))
        end
        unretain_best_effort(conn, summary_topic())
    end)

    while true do
        local ops = {
            cfg = cfg_watch:recv_op(),
            get_req = get_ep:recv_op(),
            do_req = do_ep:recv_op(),
        }
        for name, sub in pairs(status_subs) do
            ops['sub:' .. name] = sub:recv_op()
        end

        local which, a, b = fibers.perform(fibers.named_choice(ops))

        if which == 'cfg' then
            local ev, err = a, b
            if not ev then
                svc:status('failed', { reason = tostring(err or 'cfg_watch_closed') })
                error('device cfg watch closed: ' .. tostring(err), 0)
            end
            if ev.op == 'retain' then
                apply_cfg(ev.payload)
            elseif ev.op == 'unretain' then
                apply_cfg(nil)
            end
        elseif which == 'get_req' then
            local req, err = a, b
            if not req then error('device get endpoint closed: ' .. tostring(err), 0) end
            local payload = req.payload or {}
            local name = payload.component
            local rec = components[name]
            if type(name) ~= 'string' or not rec then
                req:fail('unknown_component')
            else
                if rec.status == nil and type(rec.get_topic) == 'table' then
                    local value, call_err = conn:call(rec.get_topic, payload.args or {}, { timeout = payload.timeout })
                    if value == nil then
                        req:fail(call_err)
                    else
                        rec.status = value
                        publish_component_state(conn, svc, name, rec)
                        publish_summary(conn, svc, components)
                        req:reply({ ok = true, component = component_view(name, rec, svc:now()) })
                    end
                elseif rec.status ~= nil then
                    req:reply({ ok = true, component = component_view(name, rec, svc:now()) })
                else
                    req:fail('no_status_available')
                end
            end
        elseif which == 'do_req' then
            local req, err = a, b
            if not req then error('device do endpoint closed: ' .. tostring(err), 0) end
            local payload = req.payload or {}
            local name = payload.component
            local action = payload.action
            local rec = components[name]
            if type(name) ~= 'string' or not rec then
                req:fail('unknown_component')
            elseif type(action) ~= 'string' or action == '' then
                req:fail('missing_action')
            elseif type(rec.actions[action]) ~= 'table' then
                req:fail('unsupported_action')
            else
                local value, call_err = conn:call(rec.actions[action], payload.args or {}, { timeout = payload.timeout })
                if value == nil then req:fail(call_err) else req:reply(value) end
            end
        else
            local name = which:match('^sub:(.+)$')
            local msg, err = a, b
            if name and components[name] then
                if msg then
                    components[name].status = msg.payload or msg
                else
                    components[name].status = { state = 'unavailable', err = err }
                end
                publish_component_state(conn, svc, name, components[name])
                publish_summary(conn, svc, components)
            end
        end
    end
end

return M
