-- services/ui/app.lua
--
-- Transport-facing application façade for the UI service.
--
-- HTTP and WebSocket transports call this surface; handlers own request
-- validation and business dispatch.
--
-- This small façade exists so transports depend on one stable UI surface rather
-- than the internal handler layout.

local auth_h     = require 'services.ui.handlers.auth'
local query_h    = require 'services.ui.handlers.query'
local config_h   = require 'services.ui.handlers.config'
local services_h = require 'services.ui.handlers.services'
local fabric_h   = require 'services.ui.handlers.fabric'
local call_h     = require 'services.ui.handlers.call'
local watch_h    = require 'services.ui.handlers.watch'
local update_h   = require 'services.ui.handlers.update'

local M = {}

function M.new(ctx)
	return {
		login = function(username, password)
			return auth_h.login(ctx, username, password)
		end,

		logout = function(session_id)
			return auth_h.logout(ctx, session_id)
		end,

		get_session = function(session_id)
			return auth_h.get_session(ctx, session_id)
		end,

		health = function()
			return query_h.health(ctx)
		end,

		model_exact = function(session_id, topic)
			return query_h.exact(ctx, session_id, topic)
		end,

		model_snapshot = function(session_id, pattern)
			return query_h.snapshot(ctx, session_id, pattern)
		end,

		capability_snapshot = function(session_id)
			return query_h.capability_snapshot(ctx, session_id)
		end,

		config_get = function(session_id, service_name)
			return config_h.get(ctx, session_id, service_name)
		end,

		config_set = function(session_id, service_name, data, user_conn)
			return config_h.set(ctx, session_id, service_name, data, user_conn)
		end,

		service_status = function(session_id, service_name)
			return services_h.status(ctx, session_id, service_name)
		end,

		services_snapshot = function(session_id)
			return services_h.snapshot(ctx, session_id)
		end,

		fabric_status = function(session_id)
			return fabric_h.status(ctx, session_id)
		end,

		fabric_link_status = function(session_id, link_id)
			return fabric_h.link_status(ctx, session_id, link_id)
		end,

		call = function(session_id, topic, payload, timeout, user_conn)
			return call_h.call(ctx, session_id, topic, payload, timeout, user_conn)
		end,

		watch_open = function(session_id, pattern, opts)
			return watch_h.open(ctx, session_id, pattern, opts)
		end,

		update_job_create = function(session_id, payload)
			return update_h.create(ctx, session_id, payload)
		end,

		update_job_get = function(session_id, job_id)
			return update_h.get(ctx, session_id, job_id)
		end,

		update_job_list = function(session_id)
			return update_h.list(ctx, session_id)
		end,

		update_job_do = function(session_id, job_id, payload)
			return update_h.do_job(ctx, session_id, job_id, payload)
		end,

		update_job_upload = function(session_id, stream, req_headers)
			return update_h.upload_artifact(ctx, session_id, stream, req_headers)
		end,
	}
end

return M
