-- services/device.lua
--
-- Public Device service assembly entry point.

local service = require 'services.device.service'
local config  = require 'services.device.config'
local catalogue = require 'services.device.catalogue'
local model   = require 'services.device.model'
local projection = require 'services.device.projection'
local publisher  = require 'services.device.publisher'
local observer_manager = require 'services.device.observer_manager'
local observer = require 'services.device.observer'
local action_manager = require 'services.device.action_manager'
local action_worker = require 'services.device.action_worker'
local availability = require 'services.device.availability'
local topics = require 'services.device.topics'
local fabric_stage = require 'services.device.fabric_stage'
local backpressure = require 'services.device.backpressure'

local M = {
	service = service,
	config = config,
	catalogue = catalogue,
	model = model,
	projection = projection,
	publisher = publisher,
	observer_manager = observer_manager,
	observer = observer,
	action_manager = action_manager,
	action_worker = action_worker,
	availability = availability,
	topics = topics,
	fabric_stage = fabric_stage,
	backpressure = backpressure,
}

function M.start(conn, opts)
	return service.start(conn, opts)
end

function M.run(scope, params)
	return service.run(scope, params)
end

return M
