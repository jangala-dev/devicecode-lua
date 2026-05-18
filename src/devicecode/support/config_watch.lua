-- devicecode/support/config_watch.lua
--
-- Shared retained cfg/<service> watcher for service shells.
--
-- The helper owns only the local retained subscription and event-shaping
-- mechanics.  Service modules still own validation, normalisation, generation
-- policy and effects.

local bus_cleanup = require 'devicecode.support.bus_cleanup'
local op = require 'fibers.op'

local M = {}
local Watch = {}
Watch.__index = Watch

local function cfg_topic(service)
	return { 'cfg', service }
end

local function payload_of(msg)
	return msg and msg.payload or msg
end

local function data_of(payload)
	if type(payload) == 'table' and payload.data ~= nil then
		return payload.data
	end
	return payload
end

local function rev_of(payload, fallback)
	if type(payload) == 'table' and type(payload.rev) == 'number' then
		return payload.rev
	end
	return fallback
end

local function event_from_msg(self, msg, err)
	if msg == nil then
		return {
			kind = self.closed_kind,
			service = self.service,
			err = err,
		}
	end

	local payload = payload_of(msg)
	self.generation = rev_of(payload, self.generation + 1)

	return {
		kind = self.changed_kind,
		service = self.service,
		generation = self.generation,
		rev = rev_of(payload, nil),
		raw = data_of(payload),
		record = payload,
		msg = msg,
	}
end

local function current_retained_msg(conn, topic)
	if conn == nil or type(conn.retained_view) ~= 'function' then
		return nil, nil
	end

	local ok, view_or_err = pcall(function ()
		return conn:retained_view(topic, {})
	end)
	if not ok then
		return nil, tostring(view_or_err)
	end
	if view_or_err == nil then
		return nil, nil
	end

	local view = view_or_err
	local got_ok, msg_or_err = pcall(function ()
		return view:get(topic)
	end)
	local close_ok, close_err = pcall(function ()
		if type(view.close) == 'function' then return view:close() end
	end)
	if not close_ok then
		return nil, tostring(close_err)
	end
	if not got_ok then
		return nil, tostring(msg_or_err)
	end
	return msg_or_err, nil
end

function M.open(conn, service, opts)
	opts = opts or {}
	if type(service) ~= 'string' or service == '' then
		return nil, 'config_watch.open: service must be a non-empty string'
	end

	local topic = opts.topic or cfg_topic(service)
	local sub, err = bus_cleanup.subscribe(conn, topic, {
		queue_len = opts.queue_len or opts.config_queue_len or 4,
		full = opts.full or 'reject_newest',
	})
	if not sub then return nil, err or 'config subscribe failed' end

	local watch = setmetatable({
		conn = conn,
		service = service,
		topic = topic,
		sub = sub,
		pending = {},
		generation = opts.initial_generation or 0,
		changed_kind = opts.changed_kind or 'config_changed',
		closed_kind = opts.closed_kind or 'config_closed',
	}, Watch)

	local msg, rerr = current_retained_msg(conn, topic)
	if rerr ~= nil then
		bus_cleanup.unsubscribe(conn, sub)
		return nil, 'config retained lookup failed: ' .. tostring(rerr)
	end
	if msg ~= nil then
		watch.pending[#watch.pending + 1] = event_from_msg(watch, msg, nil)
	end

	return watch, nil
end

function Watch:recv_op()
	if self.pending and #self.pending > 0 then
		local ev = table.remove(self.pending, 1)
		return op.always(ev)
	end
	return self.sub:recv_op():wrap(function (msg, err)
		return event_from_msg(self, msg, err)
	end)
end

function Watch:try_recv_now()
	if self.pending and #self.pending > 0 then
		return table.remove(self.pending, 1)
	end
	local queue = require 'devicecode.support.queue'
	local msg, err = queue.try_recv_now(self.sub)
	if msg ~= nil then return event_from_msg(self, msg, nil) end
	if err ~= 'not_ready' then return event_from_msg(self, nil, err) end
	return nil
end

function Watch:close()
	if self.sub then
		local sub = self.sub
		self.sub = nil
		return bus_cleanup.unsubscribe(self.conn, sub)
	end
	return true, nil
end

function M.topic(service)
	return cfg_topic(service)
end

M._test = {
	data_of = data_of,
	rev_of = rev_of,
	payload_of = payload_of,
}

return M
