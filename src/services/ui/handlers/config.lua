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

	local function do_call(conn)
		local ok, out, call_err = pcall(function()
			return conn:call({ 'config', service_name, 'set' }, { data = data })
		end)
		if not ok then return nil, errors.from(out, 502) end
		return out, call_err
	end

	local out, cerr
	if user_conn then
		out, cerr = do_call(user_conn)
	else
		out, cerr = ctx.with_user_conn(rec.principal, { ui = { op = 'config_set', service = service_name } }, do_call)
	end
	if out == nil then return nil, cerr or errors.upstream('config_set failed') end

	ctx.audit('config_set', { user = rec.user.id, service = service_name })
	return out, nil
end

return M
