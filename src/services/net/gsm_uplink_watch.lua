-- services/net/gsm_uplink_watch.lua
-- Retained GSM uplink-state adapter for the NET coordinator.

local bus_cleanup = require 'devicecode.support.bus_cleanup'
local queue = require 'devicecode.support.queue'
local tablex = require 'shared.table'
local topics = require 'services.net.topics'

local M = {}
local Watch = {}
Watch.__index = Watch

local NOT_READY = {}

local function copy(v) return tablex.deep_copy(v) end

local function role_from_topic(topic)
	if type(topic) ~= 'table' then return nil end
	if topic[1] == 'state' and topic[2] == 'gsm' and topic[3] == 'uplink' then
		local role = topic[4]
		if type(role) == 'string' and role ~= '' then return role end
	end
	return nil
end

local function map_event(ev)
	if ev == nil then return { kind = 'gsm_uplink_watch_closed' } end
	if type(ev) == 'table' and ev.op == 'replay_done' then return { kind = 'gsm_uplink_replay_done', origin = ev.origin } end

	local role = type(ev) == 'table' and role_from_topic(ev.topic) or nil
	if not role then return { kind = 'gsm_uplink_unknown', event = ev } end

	if ev.op == 'unretain' then
		return {
			kind = 'gsm_uplink_changed',
			role = role,
			op = ev.op,
			topic = ev.topic,
			origin = ev.origin,
			payload = {
				schema = 'devicecode.gsm.uplink/1',
				id = role,
				role = role,
				state = 'unavailable',
				connected = false,
				available = false,
				reason = 'unretained',
			},
		}
	end

	local payload = copy(ev.payload or {})
	payload.schema = payload.schema or 'devicecode.gsm.uplink/1'
	payload.id = payload.id or role
	payload.role = payload.role or role
	return {
		kind = 'gsm_uplink_changed',
		role = role,
		op = ev.op,
		topic = ev.topic,
		origin = ev.origin,
		payload = payload,
	}
end

function Watch:recv_op()
	return self._watch:recv_op():wrap(map_event)
end

function Watch:try_recv_now()
	local ev = queue.try_now(self._watch:recv_op(), NOT_READY)
	if ev == NOT_READY then return nil end
	return map_event(ev)
end

function Watch:close()
	if self._closed then return true, nil end
	self._closed = true
	return bus_cleanup.unwatch_retained(self._conn, self._watch)
end

function Watch:terminate(_reason)
	return self:close()
end

function M.open(conn, opts)
	opts = opts or {}
	local watch, err = bus_cleanup.watch_retained(conn, topics.gsm_uplink_pattern(), {
		replay = true,
		queue_len = opts.queue_len or 8,
		full = opts.full or 'reject_newest',
	})
	if not watch then return nil, err end
	return setmetatable({ _conn = conn, _watch = watch, _closed = false }, Watch), nil
end

M._test = { map_event = map_event, role_from_topic = role_from_topic }

return M
