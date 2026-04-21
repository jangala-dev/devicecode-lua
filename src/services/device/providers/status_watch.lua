local fibers = require 'fibers'
local safe = require 'coxpcall'

local M = {}

function M.spawn(scope, conn, name, rec, tx)
    local child, err = scope:child()
    if not child then return nil, err end
    local ok, spawn_err = child:spawn(function()
        local watch_topic = rec.channels and rec.channels.status and rec.channels.status.watch_topic or nil
        local get_topic = rec.channels and rec.channels.status and rec.channels.status.get_topic or nil
        if type(get_topic) == 'table' then
            local value = nil
            local okp = safe.pcall(function()
                value = conn:call(get_topic, {}, { timeout = 0.5 })
            end)
            if okp and value ~= nil then
                tx:send({ tag = 'raw_changed', component = name, payload = value })
            end
        end
        if type(watch_topic) ~= 'table' then return end
        local sub = conn:subscribe(watch_topic, { queue_len = 16, full = 'drop_oldest' })
        fibers.current_scope():finally(function()
            safe.pcall(function() sub:unsubscribe() end)
        end)
        while true do
            local msg, err2 = sub:recv()
            if msg then
                tx:send({ tag = 'raw_changed', component = name, payload = msg.payload or msg })
            else
                tx:send({ tag = 'source_down', component = name, reason = tostring(err2 or 'closed') })
                return
            end
        end
    end)
    if not ok then return nil, spawn_err end
    return child, nil
end

return M
