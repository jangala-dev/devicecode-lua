-- services/update/events.lua
--
-- Semantic event construction for update coordinators.

local priority_event = require 'devicecode.support.priority_event'
local queue          = require 'devicecode.support.queue'

local M = {}

local NOT_READY = {}

local function recv_now(rx, map)
	local item = queue.try_now(rx:recv_op(), NOT_READY)
	if item == NOT_READY then
		return nil
	end
	return map(item)
end

local function recv_op(rx, map)
	return rx:recv_op():wrap(function (item)
		return map(item)
	end)
end

function M.map_generation_done(ev)
	if ev == nil then
		return { kind = 'generation_done_queue_closed' }
	end
	return ev
end

function M.map_config_event(ev)
	if ev == nil then
		return { kind = 'config_watch_closed' }
	end

	-- Shared devicecode.support.config_watch shape.  It subscribes to cfg/<service>
	-- and normalises retained config records to config_changed/config_watch_closed
	-- events while preserving the original retained record for rev handling.
	if type(ev) == 'table' and ev.kind == 'config_watch_closed' then
		return { kind = 'config_watch_closed', err = ev.err }
	end
	if type(ev) == 'table' and ev.kind == 'config_changed' then
		return {
			kind = 'config_changed',
			payload = ev.record or ev.raw,
			origin = ev.msg and ev.msg.origin or ev.origin,
			rev = ev.rev,
			generation = ev.generation,
		}
	end

	-- Older retained-watch lifecycle shape kept for existing tests and harnesses.
	if type(ev) == 'table' and ev.op == 'retain' then
		return {
			kind = 'config_changed',
			payload = ev.payload,
			origin = ev.origin,
		}
	end
	if type(ev) == 'table' and ev.op == 'unretain' then
		return {
			kind = 'config_removed',
			origin = ev.origin,
		}
	end
	if type(ev) == 'table' and ev.op == 'replay_done' then
		return { kind = 'config_replay_done' }
	end
	return {
		kind = 'config_event_unknown',
		event = ev,
	}
end

function M.map_manager_request(item)
	if item == nil then
		return { kind = 'manager_closed' }
	end
	if type(item) == 'table' and item.closed then
		return { kind = 'manager_closed', method = item.method, reason = item.reason }
	end
	if type(item) == 'table' and item.request ~= nil then
		return {
			kind = 'manager_request',
			method = item.method,
			request = item.request,
		}
	end
	return {
		kind = 'manager_request',
		request = item,
	}
end

function M.try_generation_done_now(state)
	return recv_now(state.done_rx, M.map_generation_done)
end

function M.try_config_now(state)
	if not state.config_rx then return nil end
	return recv_now(state.config_rx, M.map_config_event)
end

function M.try_manager_now(state)
	if not state.manager_rx then return nil end
	return recv_now(state.manager_rx, M.map_manager_request)
end


function M.map_job_runtime_changed(version, snapshot, reason)
	if version == nil then
		return { kind = 'job_runtime_model_closed', reason = reason }
	end
	return {
		kind = 'job_runtime_changed',
		version = version,
		snapshot = snapshot,
	}
end

function M.try_job_runtime_now(state)
	if not state._jobs or not state._jobs_seen then return nil end
	local version, snapshot, reason = queue.try_now(state._jobs:changed_op(state._jobs_seen), NOT_READY)
	if version == NOT_READY then return nil end
	return M.map_job_runtime_changed(version, snapshot, reason)
end

function M.next_service_event_op(state)
	local sources = {
		{
			name = 'generation_done',
			try_now = function () return M.try_generation_done_now(state) end,
			recv_op = function () return recv_op(state.done_rx, M.map_generation_done) end,
		},
		{
			name = 'job_runtime',
			enabled = function () return state._jobs ~= nil and state._jobs_seen ~= nil end,
			try_now = function () return M.try_job_runtime_now(state) end,
			recv_op = function ()
				return state._jobs:changed_op(state._jobs_seen):wrap(M.map_job_runtime_changed)
			end,
		},
		{
			name = 'config',
			enabled = function () return state.config_rx ~= nil end,
			try_now = function () return M.try_config_now(state) end,
			recv_op = function () return recv_op(state.config_rx, M.map_config_event) end,
		},
	}

	-- Dependency changes are admission facts for the service coordinator.  Handle
	-- them before externally-triggered manager requests so retained status replay
	-- cannot be starved by status polling during startup.
	if state._deps and type(state._deps.event_sources) == 'function' then
		local dep_sources = state._deps:event_sources({ prefix = 'dependency' })
		for i = 1, #dep_sources do sources[#sources + 1] = dep_sources[i] end
	end

	sources[#sources + 1] = {
		name = 'manager',
		enabled = function () return state.manager_rx ~= nil end,
		try_now = function () return M.try_manager_now(state) end,
		recv_op = function () return recv_op(state.manager_rx, M.map_manager_request) end,
	}

	return priority_event.sources_op {
		label = 'update.service.next_event',
		pending = state.pending,
		sources = sources,
	}
end

return M
