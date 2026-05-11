-- services/update.lua
--
-- Public update service entry point.

local service    = require 'services.update.service'
local generation = require 'services.update.generation'
local events     = require 'services.update.events'
local model      = require 'services.update.model'
local projection = require 'services.update.projection'
local publisher  = require 'services.update.publisher'
local topics     = require 'services.update.topics'
local config     = require 'services.update.config'
local job_repository = require 'services.update.job_repository'
local job_store_cap = require 'services.update.job_store_cap'
local manager_requests = require 'services.update.manager_requests'
local active_runtime = require 'services.update.active_runtime'
local active_job = require 'services.update.active_job'
local device_component_backend = require 'services.update.backends.device_component'

return {
	start = service.start,
	run   = service.run,

	service    = service,
	generation = generation,
	events     = events,
	model      = model,
	projection = projection,
	publisher  = publisher,
	topics     = topics,
	config     = config,
	job_repository = job_repository,
	job_store_cap = job_store_cap,
	manager_requests = manager_requests,
	active_runtime = active_runtime,
	active_job = active_job,
	backends = {
		device_component = device_component_backend,
	},
}
