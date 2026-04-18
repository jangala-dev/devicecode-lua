local queries = require 'services.ui.queries'

local M = {}

function M.status(ctx, session_id, service_name)
	local rec, err = ctx.require_session(session_id)
	if not rec then return nil, err end
	return queries.service_status(ctx.model, service_name)
end

function M.snapshot(ctx, session_id)
	local rec, err = ctx.require_session(session_id)
	if not rec then return nil, err end
	return queries.services_snapshot(ctx.model)
end

return M
