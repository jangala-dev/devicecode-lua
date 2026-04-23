-- services/device/proxy.lua
--
-- Op-first helpers for the device service command surface.

local fibers = require 'fibers'

local M = {}

function M.perform_action_op(conn, rec, action_name, args, timeout)
	local route = rec.operations and rec.operations[action_name] or nil
	if not route or type(route.call_topic) ~= 'table' then
		return fibers.always(nil, 'unsupported_action')
	end
	return conn:call_op(route.call_topic, args or {}, { timeout = timeout })
end

function M.perform_action(conn, rec, action_name, args, timeout)
	return fibers.perform(M.perform_action_op(conn, rec, action_name, args, timeout))
end

return M
