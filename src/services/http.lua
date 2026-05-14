-- services/http.lua
-- Public entry point for the HTTP capability service.

local M = {
	service = require 'services.http.service',
	sdk = require 'services.http.sdk',
	headers = require 'services.http.headers',
	config = require 'services.http.config',
	policy = require 'services.http.policy',
	client = require 'services.http.client',
	listener = require 'services.http.listener',
	context = require 'services.http.context',
	websocket = require 'services.http.websocket',
	body = require 'services.http.body',
	topics = require 'services.http.topics',
}

function M.start(conn, opts)
	M.service.start(conn, opts)
end

function M.run(scope, params)
	return M.service.run(scope, params)
end

return M
