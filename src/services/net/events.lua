-- services/net/events.lua
-- Semantic event selection for the NET service coordinator.

local priority_event = require 'devicecode.support.priority_event'
local queue = require 'devicecode.support.queue'

local M = {}

local NOT_READY = {}

local function recv_now(rx, map)
	local item = queue.try_now(rx:recv_op(), NOT_READY)
	if item == NOT_READY then return nil end
	return map(item)
end

local function recv_op(rx, map)
	return rx:recv_op():wrap(function (item)
		return map(item)
	end)
end

function M.map_completion(ev)
	if ev == nil then return { kind = 'completion_queue_closed' } end
	return ev
end

function M.map_config_event(ev)
	if ev == nil then return { kind = 'config_watch_closed' } end
	if type(ev) == 'table' and ev.kind == 'config_closed' then
		return { kind = 'config_watch_closed', err = ev.err }
	end
	if type(ev) == 'table' and ev.kind == 'config_changed' then
		return {
			kind = 'config_changed',
			payload = ev.record or ev.raw,
			rev = ev.rev,
			watch_generation = ev.generation,
			origin = ev.msg and ev.msg.origin or ev.origin,
		}
	end
	return { kind = 'config_event_unknown', event = ev }
end

function M.map_observed_event(msg)
	if msg == nil then return { kind = 'observation_closed' } end
	local payload = msg.payload or msg
	return {
		kind = 'observed_state',
		event = payload,
		origin = msg.origin,
		topic = msg.topic,
	}
end

function M.map_capability_status(name, msg)
	if msg == nil then return { kind = 'capability_status_closed', capability = name } end
	return {
		kind = 'capability_status',
		capability = name,
		payload = msg.payload,
		origin = msg.origin,
		topic = msg.topic,
	}
end

local function try_config_now(state)
	if not state.config_watch then return nil end
	local ev = state.config_watch:try_recv_now()
	if ev == nil then return nil end
	return M.map_config_event(ev)
end

local function try_observed_now(state)
	if not state.observed_sub then return nil end
	local ev = queue.try_now(state.observed_sub:recv_op(), NOT_READY)
	if ev == NOT_READY then return nil end
	return M.map_observed_event(ev)
end

local function add_capability_sources(state, sources)
	local subs = state.capability_status_subs or {}
	local names = {}
	for name in pairs(subs) do names[#names + 1] = name end
	table.sort(names)
	for i = 1, #names do
		local name = names[i]
		local sub = subs[name]
		sources[#sources + 1] = {
			name = 'capability_' .. tostring(name),
			try_now = function () return recv_now(sub, function (msg) return M.map_capability_status(name, msg) end) end,
			recv_op = function () return recv_op(sub, function (msg) return M.map_capability_status(name, msg) end) end,
		}
	end
end

function M.next_service_event_op(state)
	local sources = {
		{
			name = 'completion',
			try_now = function () return recv_now(state.done_rx, M.map_completion) end,
			recv_op = function () return recv_op(state.done_rx, M.map_completion) end,
		},
		{
			name = 'config',
			enabled = function () return state.config_watch ~= nil end,
			try_now = function () return try_config_now(state) end,
			recv_op = function () return state.config_watch:recv_op():wrap(M.map_config_event) end,
		},
		{
			name = 'observed',
			enabled = function () return state.observed_sub ~= nil end,
			try_now = function () return try_observed_now(state) end,
			recv_op = function () return state.observed_sub:recv_op():wrap(M.map_observed_event) end,
		},
	}
	add_capability_sources(state, sources)

	return priority_event.sources_op {
		label = 'net.service.next_event',
		pending = state.pending,
		sources = sources,
	}
end

return M
