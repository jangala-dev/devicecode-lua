local fibers    = require 'fibers'
local pulse     = require 'fibers.pulse'
local mailbox   = require 'fibers.mailbox'
local base      = require 'devicecode.service_base'
local safe      = require 'coxpcall'
local model     = require 'services.device.model'
local projection= require 'services.device.projection'
local observers = require 'services.device.observers'
local proxy     = require 'services.device.proxy'

local M = {}
local SCHEMA = 'devicecode.config/device/1'

local function retain_best_effort(conn, topic, payload)
    safe.pcall(function() conn:retain(topic, payload) end)
end

local function unretain_best_effort(conn, topic)
    safe.pcall(function() conn:unretain(topic) end)
end

function M.start(conn, opts)
    opts = opts or {}
    local service_scope = assert(fibers.current_scope())
    local svc = base.new(conn, { name = opts.name or 'device', env = opts.env })
    svc:status('starting')
    svc:spawn_heartbeat((opts.heartbeat_s or 30.0), 'tick')

    local state = model.new_state(SCHEMA)
    local changed = pulse.scoped({ close_reason = 'device service stopping' })
    local cfg_watch = conn:watch_retained({ 'cfg', 'device' }, { replay = true, queue_len = 8, full = 'drop_oldest' })
    local obs_tx, obs_rx = mailbox.new(128, { full = 'drop_oldest' })
    local observer_scopes = {}

    local self_ep = conn:bind({ 'cmd', 'device', 'get' }, { queue_len = 32 })
    local list_ep = conn:bind({ 'cmd', 'device', 'component', 'list' }, { queue_len = 32 })
    local get_ep = conn:bind({ 'cmd', 'device', 'component', 'get' }, { queue_len = 32 })
    local do_ep = conn:bind({ 'cmd', 'device', 'component', 'do' }, { queue_len = 32 })

    local function publish_component(name)
        local rec = state.components[name]
        if not rec then return end
        local ts = svc:now()
        retain_best_effort(conn, projection.component_topic(name), projection.component_view(name, rec, ts))
        retain_best_effort(conn, projection.component_software_topic(name), projection.software_payload(name, rec, ts))
        retain_best_effort(conn, projection.component_update_topic(name), projection.update_payload(name, rec, ts))
        model.clear_component_dirty(state, name)
    end

    local function publish_summary()
        local ts = svc:now()
        retain_best_effort(conn, projection.summary_topic(), projection.summary_payload(state, ts))
        retain_best_effort(conn, projection.self_topic(), projection.self_payload(state, ts))
        model.set_summary_clean(state)
    end

    local function close_observers()
        for _, child in pairs(observer_scopes) do
            safe.pcall(function() child:cancel('rebuild observers') end)
        end
        observer_scopes = {}
    end

    local function rebuild_observers()
        close_observers()
        for name, rec in pairs(state.components) do
            local child, err = observers.spawn_component(service_scope, conn, name, rec, obs_tx)
            if child then
                observer_scopes[name] = child
            else
                svc:obs_log('warn', { what = 'observer_spawn_failed', component = name, err = tostring(err) })
            end
        end
    end

    local function apply_cfg(payload)
        local old = {}
        for name in pairs(state.components) do old[name] = true end
        model.apply_cfg(state, payload)
        for name in pairs(old) do
            if not state.components[name] then
                unretain_best_effort(conn, projection.component_topic(name))
                unretain_best_effort(conn, projection.component_software_topic(name))
                unretain_best_effort(conn, projection.component_update_topic(name))
            end
        end
        rebuild_observers()
        changed:signal()
    end

    apply_cfg(nil)
    svc:status('running')
    changed:signal()

    fibers.current_scope():finally(function()
        close_observers()
        safe.pcall(function() self_ep:unbind() end)
        safe.pcall(function() list_ep:unbind() end)
        safe.pcall(function() get_ep:unbind() end)
        safe.pcall(function() do_ep:unbind() end)
        for name, _ in pairs(state.components) do
            unretain_best_effort(conn, projection.component_topic(name))
            unretain_best_effort(conn, projection.component_software_topic(name))
            unretain_best_effort(conn, projection.component_update_topic(name))
        end
        unretain_best_effort(conn, projection.self_topic())
        unretain_best_effort(conn, projection.summary_topic())
    end)

    local seen = changed:version()
    while true do
        local ops = {
            cfg = cfg_watch:recv_op(),
            obs = obs_rx:recv_op(),
            self_req = self_ep:recv_op(),
            list_req = list_ep:recv_op(),
            get_req = get_ep:recv_op(),
            do_req = do_ep:recv_op(),
            changed = changed:changed_op(seen):wrap(function(ver) seen = ver; return ver end),
        }
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
        elseif which == 'obs' then
            local ev = a
            if ev and ev.tag == 'raw_changed' then
                model.note_status(state, ev.component, ev.payload)
                changed:signal()
            elseif ev and ev.tag == 'source_down' then
                model.note_source_down(state, ev.component, ev.reason)
                changed:signal()
            end
        elseif which == 'changed' then
            for name in pairs(state.dirty_components) do publish_component(name) end
            if state.summary_dirty then publish_summary() end
        elseif which == 'self_req' then
            local req, err = a, b
            if not req then error('device self endpoint closed: ' .. tostring(err), 0) end
            req:reply({ ok = true, device = projection.self_payload(state, svc:now()) })
        elseif which == 'list_req' then
            local req, err = a, b
            if not req then error('device list endpoint closed: ' .. tostring(err), 0) end
            local items = {}
            for name, rec in pairs(state.components) do items[#items + 1] = projection.component_view(name, rec, svc:now()) end
            table.sort(items, function(x, y) return tostring(x.component) < tostring(y.component) end)
            req:reply({ ok = true, components = items })
        elseif which == 'get_req' then
            local req, err = a, b
            if not req then error('device get endpoint closed: ' .. tostring(err), 0) end
            local payload = req.payload or {}
            local name = payload.component
            local rec = state.components[name]
            if type(name) ~= 'string' or not rec then
                req:fail('unknown_component')
            else
                if rec.raw_status == nil then
                    local value, call_err = proxy.fetch_status(conn, rec, payload.args or {}, payload.timeout)
                    if value == nil then
                        req:fail(call_err)
                    else
                        model.note_status(state, name, value)
                        publish_component(name)
                        publish_summary()
                        req:reply({ ok = true, component = projection.component_view(name, rec, svc:now()) })
                    end
                else
                    req:reply({ ok = true, component = projection.component_view(name, rec, svc:now()) })
                end
            end
        elseif which == 'do_req' then
            local req, err = a, b
            if not req then error('device do endpoint closed: ' .. tostring(err), 0) end
            local payload = req.payload or {}
            local name = payload.component
            local action = payload.action
            local rec = state.components[name]
            if type(name) ~= 'string' or not rec then
                req:fail('unknown_component')
            else
                local value, call_err = proxy.perform_action(conn, rec, action, payload.args or {}, payload.timeout)
                if value == nil then req:fail(call_err) else req:reply(value) end
            end
        end
    end
end

return M
