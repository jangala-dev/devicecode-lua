-- services/ui/handlers/config.lua
--
-- UI config handlers.

local errors  = require 'services.ui.errors'
local queries = require 'services.ui.queries'

local M = {}

function M.get(ctx, session_id, service_name)
	local rec, err = ctx.require_session(session_id)
	if not rec then return nil, err end
	return queries.config_get(ctx.model, service_name)
end

function M.set(ctx, session_id, service_name, data, user_conn)
	local rec, err = ctx.require_session(session_id)
	if not rec then return nil, err end

	if type(service_name) ~= 'string' or service_name == '' then
		return nil, errors.bad_request('service_name must be a non-empty string')
	end
	if type(data) ~= 'table' or getmetatable(data) ~= nil then
		return nil, errors.bad_request('data must be a plain table')
	end

	local out, cerr = ctx.run_user_call(
		rec,
		{ ui = { op = 'config_set', service = service_name } },
		user_conn,
		function(conn)
			return conn:call({ 'config', service_name, 'set' }, { data = data })
		end
	)

	if out == nil then
		return nil, cerr or errors.upstream('config_set failed')
	end

	ctx.audit('config_set', {
		user = rec.user.id,
		service = service_name,
	})

	return out, nil
end

return M
