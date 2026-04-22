local fibers = require 'fibers'

local M = {}

function M.run(ctx)
    local conn = ctx.conn
    local name = ctx.component
    local rec = ctx.rec
    local emit = ctx.emit

    local watch_topic = rec.channels and rec.channels.status and rec.channels.status.watch_topic or nil
    local get_topic = rec.channels and rec.channels.status and rec.channels.status.get_topic or nil

    if type(get_topic) == 'table' then
        local value = conn:call(get_topic, {}, { timeout = 0.5 })
        if value ~= nil then
            emit({ tag = 'raw_changed', component = name, payload = value })
        end
    end

    if type(watch_topic) ~= 'table' then return end

    local sub = conn:subscribe(watch_topic, { queue_len = 16, full = 'drop_oldest' })
    fibers.current_scope():finally(function()
        sub:unsubscribe()
    end)

    while true do
        local msg, err2 = sub:recv()
        if msg then
            emit({ tag = 'raw_changed', component = name, payload = msg.payload or msg })
        else
            emit({ tag = 'source_down', component = name, reason = tostring(err2 or 'closed') })
            return
        end
    end
end

return M
