-- services/ui/handlers/call.lua
--
-- UI call handler.

local errors = require 'services.ui.errors'
local topics = require 'services.ui.topics'

local M = {}

function M.call(ctx, session_id, topic, payload, timeout, user_conn)
	local rec, err = ctx.require_session(session_id)
	if not rec then return nil, err end

	local norm, nerr = topics.normalise_topic(topic, {
		allow_wildcards = false,
		allow_numbers = true,
	})
	if not norm then return nil, errors.bad_request(nerr) end

	local out, cerr = ctx.run_user_call(
		rec,
		{ ui = { op = 'call', topic = norm } },
		user_conn,
		function(conn)
			return conn:call(norm, payload, {
				timeout = timeout,
				extra = { via = 'ui' },
			})
		end
	)

	if out == nil then
		return nil, cerr or errors.upstream('call failed')
	end

	return out, nil
end

return M
