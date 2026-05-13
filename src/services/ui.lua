-- services/ui.lua
--
-- Public UI service assembly entry point. Semantic owners live under
-- services.ui.*; this file is deliberately thin.

local M = {
	service = require 'services.ui.service',
	topics = require 'services.ui.topics',
	errors = require 'services.ui.errors',
	config = require 'services.ui.config',
	sessions = require 'services.ui.sessions',
	auth = require 'services.ui.auth',
	read_model = require 'services.ui.read_model',
	read_model_store = require 'services.ui.read_model_store',
	read_model_watches = require 'services.ui.read_model_watches',
	queries = require 'services.ui.queries',
	user_operation = require 'services.ui.user_operation',
	http = {
		listener = require 'services.ui.http.listener',
		request = require 'services.ui.http.request',
		routes = require 'services.ui.http.routes',
		response = require 'services.ui.http.response',
		static = require 'services.ui.http.static',
		sse = require 'services.ui.http.sse',
	},
	update = {
		client = require 'services.ui.update.client',
		upload = require 'services.ui.update.upload',
		artifact_ingest = require 'services.ui.update.artifact_ingest',
	},
}

function M.start(conn, opts)
	return M.service.start(conn, opts)
end

function M.run(scope, params)
	return M.service.run(scope, params)
end

return M
