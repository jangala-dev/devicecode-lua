
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
            status_topic = { 'cap', 'updater', 'cm5', 'state', 'status' },
            commands = {
                status = { 'cap', 'updater', 'cm5', 'rpc', 'status' },
                prepare = { 'cap', 'updater', 'cm5', 'rpc', 'prepare' },
                stage = { 'cap', 'updater', 'cm5', 'rpc', 'stage' },
                commit = { 'cap', 'updater', 'cm5', 'rpc', 'commit' },
            },
        },
    }
end

local function merge_components(cfg)
    local out = default_components()
    if type(cfg) ~= 'table' then return out end
    if cfg.schema ~= nil and cfg.schema ~= SCHEMA then return out end
    local comps = cfg.components or cfg
    if type(comps) ~= 'table' then return out end
    for name, spec in pairs(comps) do
        if type(name) == 'string' and type(spec) == 'table' then
            local cur = out[name] or { name = name, commands = {} }
            if type(spec.status_topic) == 'table' then cur.status_topic = copy_array(spec.status_topic) end
            if type(spec.commands) == 'table' then
                cur.commands = cur.commands or {}
                for op_name, topic in pairs(spec.commands) do
                    if type(op_name) == 'string' and type(topic) == 'table' then
                        cur.commands[op_name] = copy_array(topic)
                    end
                end
            end
            out[name] = cur
        end
    end
    return out
end

local function publish_component_state(conn, svc, name, rec)
    retain_best_effort(conn, component_topic(name), {
        kind = 'device.component',
        component = name,
        ts = svc:now(),
        status = rec.status,
        source_topic = rec.status_topic,
        commands = rec.commands,
    })
end

local function publish_summary(conn, svc, components)
    local items = {}
    for name, rec in pairs(components) do
        items[name] = {
            ready = rec.status ~= nil,
            state = type(rec.status) == 'table' and (rec.status.state or rec.status.status or rec.status.kind) or nil,
            source_topic = rec.status_topic,
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
        if type(rec.commands) == 'table' and type(rec.commands.status) == 'table' then
            local value = nil
            local ok = safe.pcall(function()
                value = conn:call(rec.commands.status, {}, { timeout = 0.5 })
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
            rec.commands = rec.commands or {}
        end
        rebuild_status_subs()
    end

    apply_cfg(nil)

    local status_ep = conn:bind({ 'cmd', 'device', 'component', 'status' }, { queue_len = 32 })
    local update_ep = conn:bind({ 'cmd', 'device', 'component', 'update' }, { queue_len = 32 })

    svc:status('running')

    fibers.current_scope():finally(function()
        close_status_subs()
        pcall(function() status_ep:unbind() end)
        pcall(function() update_ep:unbind() end)
        for name, _ in pairs(components) do
            unretain_best_effort(conn, component_topic(name))
        end
        unretain_best_effort(conn, summary_topic())
    end)

    while true do
        local ops = {
            cfg = cfg_watch:recv_op(),
            status_req = status_ep:recv_op(),
            update_req = update_ep:recv_op(),
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
        elseif which == 'status_req' then
            local req, err = a, b
            if not req then error('device status endpoint closed: ' .. tostring(err), 0) end
            local payload = req.payload or {}
            local name = payload.component
            local rec = components[name]
            if type(name) ~= 'string' or not rec then
                req:fail('unknown_component')
            elseif rec.status ~= nil then
                req:reply({ ok = true, component = name, state = rec.status })
            elseif type(rec.commands.status) == 'table' then
                local value, call_err = conn:call(rec.commands.status, payload.args or {}, { timeout = payload.timeout })
                if value == nil then req:fail(call_err) else req:reply({ ok = true, component = name, state = value }) end
            else
                req:fail('no_status_available')
            end
        elseif which == 'update_req' then
            local req, err = a, b
            if not req then error('device update endpoint closed: ' .. tostring(err), 0) end
            local payload = req.payload or {}
            local name = payload.component
            local op_name = payload.op
            local rec = components[name]
            if type(name) ~= 'string' or not rec then
                req:fail('unknown_component')
            elseif type(op_name) ~= 'string' or op_name == '' then
                req:fail('missing_op')
            elseif type(rec.commands[op_name]) ~= 'table' then
                req:fail('unsupported_op')
            else
                local value, call_err = conn:call(rec.commands[op_name], payload.args or {}, { timeout = payload.timeout })
                if value == nil then req:fail(call_err) else req:reply(value) end
            end
        else
            local name = which:match('^sub:(.+)$')
            local msg, err = a, b
            if name and components[name] then
                if msg then
                    components[name].status = msg.payload or msg
                    publish_component_state(conn, svc, name, components[name])
                    publish_summary(conn, svc, components)
                else
                    components[name].status = { state = 'unavailable', err = err }
                    publish_component_state(conn, svc, name, components[name])
                    publish_summary(conn, svc, components)
                end
            end
        end
    end
end

return M
