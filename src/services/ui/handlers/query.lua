-- services/ui/handlers/query.lua
--
-- Query/read handlers over the UI model.

local errors  = require 'services.ui.errors'
local queries = require 'services.ui.queries'
local topics  = require 'services.ui.topics'

local M = {}

function M.health(ctx)
	return {
		service = ctx.svc.name,
		now = ctx.now(),
		sessions = ctx.sessions:count(),
		model_ready = ctx.model:is_ready(),
		model_seq = ctx.model:seq(),
	}, nil
end

function M.exact(ctx, session_id, topic)
	local rec, err = ctx.require_session(session_id)
	if not rec then return nil, err end

	local norm, nerr = topics.normalise_topic(topic, {
		allow_wildcards = false,
		allow_numbers = true,
	})
	if not norm then return nil, errors.bad_request(nerr) end

	local entry, gerr = ctx.model:get_exact(norm)
	if not entry then return nil, gerr end
	return entry, nil
end

function M.snapshot(ctx, session_id, pattern)
	local rec, err = ctx.require_session(session_id)
	if not rec then return nil, err end

	local norm, nerr = topics.normalise_topic(pattern, {
		allow_wildcards = true,
		allow_numbers = true,
	})
	if not norm then return nil, errors.bad_request(nerr) end

	return ctx.model:snapshot(norm)
end

function M.capability_snapshot(ctx, session_id)
	local rec, err = ctx.require_session(session_id)
	if not rec then return nil, err end
	return queries.capability_snapshot(ctx.model)
end

return M
