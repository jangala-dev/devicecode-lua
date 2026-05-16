-- services/net.lua
-- Public entry point for the NET service.

local M = {
	service = require 'services.net.service',
	config = require 'services.net.config',
	model = require 'services.net.model',
	topics = require 'services.net.topics',
	projection = require 'services.net.projection',
	publisher = require 'services.net.publisher',
	events = require 'services.net.events',
	backpressure = require 'services.net.backpressure',
	generation = require 'services.net.generation',
	apply_runtime = require 'services.net.apply_runtime',
	hal_client = require 'services.net.hal_client',
}

function M.start(conn, opts)
	return M.service.start(conn, opts)
end

function M.run(scope, params)
	return M.service.run(scope, params)
end

return M
