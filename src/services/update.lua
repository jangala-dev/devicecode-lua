-- services/update.lua
-- Public update service entry point.

local M = {
	service    = require 'services.update.service',
	generation = require 'services.update.generation',
	events     = require 'services.update.events',
	model      = require 'services.update.model',
	projection = require 'services.update.projection',
	publisher  = require 'services.update.publisher',
	topics     = require 'services.update.topics',
	config     = require 'services.update.config',
	job_repository = require 'services.update.job_repository',
	job_store_memory = require 'services.update.job_store_memory',
	job_store_control_store = require 'services.update.job_store_control_store',
	manager_requests = require 'services.update.manager_requests',
	active_runtime = require 'services.update.active_runtime',
	active_job = require 'services.update.active_job',
}

function M.start(conn, opts)
	M.service.start(conn, opts)
end

function M.run(scope, params)
	return M.service.run(scope, params)
end

return M
