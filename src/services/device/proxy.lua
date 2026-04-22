-- services/device/proxy.lua
--
-- Thin call helpers for component status and action routes.
--
-- Design notes:
--   * this module is intentionally transport-thin
--   * it exposes op-first helpers so callers can compose with choice/timeouts
--   * blocking wrappers remain for ordinary service code
--   * this module does not own policy or projection rules

local fibers = require 'fibers'
local projection = require 'services.device.projection'

local M = {}

function M.fetch_status_op(conn, rec, args, timeout)
	local get_topic = rec.channels and rec.channels.status and rec.channels.status.get_topic or nil
	if type(get_topic) ~= 'table' then
		return fibers.always(nil, 'no_status_available')
	end
	return conn:call_op(get_topic, args or {}, { timeout = timeout })
end

function M.fetch_status(conn, rec, args, timeout)
	return fibers.perform(M.fetch_status_op(conn, rec, args, timeout))
end

function M.perform_action_op(conn, rec, action, args, timeout)
	if type(action) ~= 'string' or action == '' then
		return fibers.always(nil, 'missing_action')
	end

	local op = rec.operations and rec.operations[action] or nil
	if type(op) ~= 'table' or type(op.call_topic) ~= 'table' then
		return fibers.always(nil, 'unsupported_action')
	end

	return conn:call_op(op.call_topic, args or {}, { timeout = timeout })
end

function M.perform_action(conn, rec, action, args, timeout)
	return fibers.perform(M.perform_action_op(conn, rec, action, args, timeout))
end

function M.public_component(rec, name, now_ts)
	return projection.component_view(name, rec, now_ts)
end

return M
