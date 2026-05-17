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


function M.map_gsm_event(msg)
	if msg == nil then return { kind = 'gsm_subscription_closed' } end
	local topic = msg.topic or {}
	local payload = msg.payload
	local modem = topic[4]
	local field = topic[5]
	if field == 'uplink' then
		return { kind = 'gsm_uplink', modem = modem, uplink = payload, topic = topic, origin = msg.origin }
	end
	if field == 'connected' or field == 'wwan-iface' then
		return { kind = 'gsm_legacy', modem = modem, field = field, value = payload, topic = topic, origin = msg.origin }
	end
	return { kind = 'gsm_unknown', topic = topic, payload = payload }
end

local function try_gsm_now(state)
	if not state.gsm_sub then return nil end
	local ev = queue.try_now(state.gsm_sub:recv_op(), NOT_READY)
	if ev == NOT_READY or ev == nil then return nil end
	return M.map_gsm_event(ev)
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
	if ev == NOT_READY or ev == nil then return nil end
	return M.map_observed_event(ev)
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
			name = 'gsm',
			enabled = function () return state.gsm_sub ~= nil end,
			try_now = function () return try_gsm_now(state) end,
			recv_op = function () return state.gsm_sub:recv_op():wrap(M.map_gsm_event) end,
		},
		{
			name = 'observed',
			enabled = function () return state.observed_sub ~= nil end,
			try_now = function () return try_observed_now(state) end,
			recv_op = function () return state.observed_sub:recv_op():wrap(M.map_observed_event) end,
		},
	}

	return priority_event.sources_op {
		label = 'net.service.next_event',
		pending = state.pending,
		sources = sources,
	}
end

return M
