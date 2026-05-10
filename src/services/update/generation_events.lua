-- services/update/generation_events.lua
--
-- Semantic event construction for a generation coordinator.

local priority_event  = require 'devicecode.support.priority_event'
local queue           = require 'devicecode.support.queue'
local service_events  = require 'devicecode.support.service_events'

local M = {}

local NOT_READY = {}

function M.map_done(ev)
	if ev == nil then return { kind = 'completion_queue_closed' } end
	return ev
end

function M.map_manager(req)
	if req == nil then return { kind = 'manager_closed' } end
	if service_events.is_route_event(req) then return req end
	return { kind = 'manager_request', request = req }
end

function M.map_service(ev)
	if ev == nil then return { kind = 'service_route_closed' } end
	if service_events.is_route_event(ev) then return ev end
	return ev
end

local function try_recv_now(rx, map)
	local item = queue.try_now(rx:recv_op(), NOT_READY)
	if item == NOT_READY then return nil end
	return map(item)
end

function M.next_op(state)
	return priority_event.sources_op {
		label = 'update.generation.next_event',
		pending = state.pending,
		sources = {
			{
				name = 'done',
				try_now = function () return try_recv_now(state.done_rx, M.map_done) end,
				recv_op = function () return state.done_rx:recv_op():wrap(M.map_done) end,
			},
			{
				name = 'ingest_terminal',
				enabled = function () return state._ingest ~= nil end,
				try_now = function () return state._ingest:try_terminal_now() end,
				recv_op = function () return state._ingest:terminal_op() end,
			},
			{
				name = 'ingest_request',
				enabled = function () return state._ingest ~= nil end,
				try_now = function () return state._ingest:try_request_now() end,
				recv_op = function () return state._ingest:request_op() end,
			},
			{
				name = 'service',
				enabled = function () return state.service_rx ~= nil end,
				try_now = function () return try_recv_now(state.service_rx, M.map_service) end,
				recv_op = function () return state.service_rx:recv_op():wrap(M.map_service) end,
			},
			{
				name = 'manager',
				enabled = function () return state.manager_rx ~= nil end,
				try_now = function () return try_recv_now(state.manager_rx, M.map_manager) end,
				recv_op = function () return state.manager_rx:recv_op():wrap(M.map_manager) end,
			},
		},
	}
end

return M
