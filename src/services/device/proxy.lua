local projection = require 'services.device.projection'

local M = {}

function M.fetch_status(conn, rec, args, timeout)
    local get_topic = rec.channels and rec.channels.status and rec.channels.status.get_topic or nil
    if type(get_topic) ~= 'table' then return nil, 'no_status_available' end
    return conn:call(get_topic, args or {}, { timeout = timeout })
end

function M.perform_action(conn, rec, action, args, timeout)
    if type(action) ~= 'string' or action == '' then return nil, 'missing_action' end
    local op = rec.operations and rec.operations[action] or nil
    if type(op) ~= 'table' or type(op.call_topic) ~= 'table' then return nil, 'unsupported_action' end
    return conn:call(op.call_topic, args or {}, { timeout = timeout })
end

function M.public_component(rec, name, now_ts)
    return projection.component_view(name, rec, now_ts)
end

return M
