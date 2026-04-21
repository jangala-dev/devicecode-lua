local auth_h     = require 'services.ui.handlers.auth'
local query_h    = require 'services.ui.handlers.query'
local config_h   = require 'services.ui.handlers.config'
local services_h = require 'services.ui.handlers.services'
local fabric_h   = require 'services.ui.handlers.fabric'
local call_h     = require 'services.ui.handlers.call'
local watch_h    = require 'services.ui.handlers.watch'
local update_h   = require 'services.ui.handlers.update'
local queries    = require 'services.ui.queries'

local M = {}

function M.new(ctx)
	local app = {}

	function app.login(username, password)
		return auth_h.login(ctx, username, password)
	end

	function app.logout(session_id)
		return auth_h.logout(ctx, session_id)
	end

	function app.get_session(session_id)
		return auth_h.get_session(ctx, session_id)
	end

	function app.health()
		return query_h.health(ctx)
	end

	function app.model_exact(session_id, topic)
		return query_h.exact(ctx, session_id, topic)
	end

	function app.model_snapshot(session_id, pattern)
		return query_h.snapshot(ctx, session_id, pattern)
	end

	function app.config_get(session_id, service_name)
		return config_h.get(ctx, session_id, service_name)
	end

	function app.config_set(session_id, service_name, data, user_conn)
		return config_h.set(ctx, session_id, service_name, data, user_conn)
	end

	function app.service_status(session_id, service_name)
		return services_h.status(ctx, session_id, service_name)
	end

	function app.services_snapshot(session_id)
		return services_h.snapshot(ctx, session_id)
	end

	function app.fabric_status(session_id)
		return fabric_h.status(ctx, session_id)
	end

	function app.fabric_link_status(session_id, link_id)
		return fabric_h.link_status(ctx, session_id, link_id)
	end

	function app.capability_snapshot(session_id)
		local rec, err = ctx.require_session(session_id)
		if not rec then return nil, err end
		return queries.capability_snapshot(ctx.model)
	end

	function app.call(session_id, topic, payload, timeout, user_conn)
		return call_h.call(ctx, session_id, topic, payload, timeout, user_conn)
	end

	function app.watch_open(session_id, pattern, opts)
		return watch_h.open(ctx, session_id, pattern, opts)
	end

	function app.update_job_create(session_id, payload)
		return update_h.create(ctx, session_id, payload)
	end

	function app.update_job_get(session_id, job_id)
		return update_h.get(ctx, session_id, job_id)
	end

	function app.update_job_list(session_id)
		return update_h.list(ctx, session_id)
	end

	function app.update_job_do(session_id, job_id, payload)
		return update_h.do_job(ctx, session_id, job_id, payload)
	end

	function app.update_job_upload(session_id, job_id, stream, req_headers)
		return update_h.upload_artifact(ctx, session_id, job_id, stream, req_headers)
	end

	return app
end

return M
