local errors = require 'services.ui.errors'
local topics = require 'services.ui.topics'

local M = {}

function M.open(ctx, session_id, pattern, opts)
	local rec, err = ctx.require_session(session_id)
	if not rec then return nil, err end
	local norm, nerr = topics.normalise_topic(pattern, { allow_wildcards = true, allow_numbers = true })
	if not norm then return nil, errors.bad_request(nerr) end
	return ctx.model:open_watch(norm, opts)
end

return M
