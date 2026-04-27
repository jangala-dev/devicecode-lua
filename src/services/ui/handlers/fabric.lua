-- services/ui/handlers/fabric.lua
--
-- UI fabric read handlers.

local queries = require 'services.ui.queries'

local M = {}

function M.status(ctx, session_id)
	local rec, err = ctx.require_session(session_id)
	if not rec then return nil, err end
	return queries.fabric_status(ctx.model)
end

function M.link_status(ctx, session_id, link_id)
	local rec, err = ctx.require_session(session_id)
	if not rec then return nil, err end
	return queries.fabric_link_status(ctx.model, link_id)
end

return M
