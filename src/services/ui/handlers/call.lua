local safe   = require 'coxpcall'
local errors = require 'services.ui.errors'
local topics = require 'services.ui.topics'

local M = {}

function M.call(ctx, session_id, topic, payload, timeout, user_conn)
	local rec, err = ctx.require_session(session_id)
	if not rec then return nil, err end
	local norm, nerr = topics.normalise_topic(topic, { allow_wildcards = false, allow_numbers = true })
	if not norm then return nil, errors.bad_request(nerr) end

	local function do_call(conn)
		local ok, out, call_err = safe.pcall(function()
			return conn:call(norm, payload, {
				timeout = timeout,
				extra = { via = 'ui' },
			})
		end)
		if not ok then return nil, errors.from(out, 502) end
		return out, call_err
	end

	local out, cerr
	if user_conn then
		out, cerr = do_call(user_conn)
	else
		out, cerr = ctx.with_user_conn(rec.principal, { ui = { op = 'call', topic = norm } }, do_call)
	end
	if out == nil then return nil, cerr or errors.upstream('call failed') end
	return out, nil
end

return M
