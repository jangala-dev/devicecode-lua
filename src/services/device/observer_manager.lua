-- services/device/observer_manager.lua
--
-- Starts and tracks generation-owned component observer scopes.

local scoped_work = require 'devicecode.support.scoped_work'
local queue       = require 'devicecode.support.queue'
local service_events = require 'devicecode.support.service_events'
local observer    = require 'services.device.observer'

local M = {}


local function completion_reporter(params, identity, label)
	local target = params.events_port or params.done_tx
	if type(target) == 'table'
		and (type(target.emit_required) == 'function' or type(target.send_op) == 'function')
	then
		return service_events.reporter_for(target, identity, { label = label })
	end
	return function (ev)
		return queue.try_admit_required(params.done_tx, ev, label)
	end
end

local function observer_identity(generation, component_id)
	return {
		kind = 'observer_done',
		generation = generation,
		component = component_id,
	}
end

function M.start_component(active, params, component_id, component)
	local handle, err = scoped_work.start {
		lifetime_scope = active.observer_root or active.scope,
		reaper_scope   = active.observer_root or active.scope,
		report_scope   = params.report_scope or params.service_scope,
		identity = observer_identity(active.generation, component_id),
		run = function (scope)
			return observer.run(scope, {
				conn = params.conn,
				tx = params.observation_tx,
				generation = active.generation,
				component_id = component_id,
				component = component,
			})
		end,
		report = completion_reporter(params, observer_identity(active.generation, component_id), 'device_observer_done_report_failed'),
	}

	if not handle then return nil, err end
	active.observers[component_id] = handle
	return handle, nil
end

function M.start_all(active, params)
	active.observers = active.observers or {}
	for component_id, component in pairs((active.catalogue and active.catalogue.components) or {}) do
		local handle, err = M.start_component(active, params, component_id, component)
		if not handle then
			return nil, err or ('observer_start_failed:' .. tostring(component_id))
		end
	end
	return true, nil
end

return M
