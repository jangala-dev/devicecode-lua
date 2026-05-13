-- devicecode/support/service_events.lua
--
-- Small event-port helper for fibres services.
--
-- Vocabulary:
--   source     = the component/adapter that produced the event
--   source_id  = the identity of that source instance
--   generation = generation/version boundary when applicable
--   event      = immutable coordinator input
--   port       = immediate, non-blocking event admission surface
--
-- A port is deliberately not a callback into a parent. It only constructs and
-- admits events to a queue using the public queue helpers. Coordinators remain
-- the sole owners of their state.

local queue  = require 'devicecode.support.queue'
local tablex = require 'shared.table'

local M = {}

local copy_table = tablex.shallow_copy

local normalise_event

local Port = {}
Port.__index = Port

local TargetPort = {}
TargetPort.__index = TargetPort

function TargetPort:event(ev, attrs)
	local out = normalise_event(ev, attrs)
	for k, v in pairs(self._identity or {}) do
		if out[k] == nil then out[k] = v end
	end
	if self._mark_route_events then
		out._service_event = true
	end
	return out
end

function TargetPort:emit_required(ev, attrs, label)
	if type(attrs) == 'string' and label == nil then
		label = attrs
		attrs = nil
	end
	return self._target:emit_required(
		self:event(ev, attrs),
		label or self._label or 'service_event_admission_failed'
	)
end

function TargetPort:emit_now(ev, attrs)
	if type(self._target.emit_now) == 'function' then
		return self._target:emit_now(self:event(ev, attrs))
	end
	return self:emit_required(ev, attrs, self._label or 'service_event_admission_failed')
end

function TargetPort:assert_emit_required(ev, attrs, label)
	local ok, err = self:emit_required(ev, attrs, label)
	if ok ~= true then error(err or 'service_event_admission_failed', 2) end
	return true
end

function TargetPort:identity()
	return copy_table(self._identity)
end


function normalise_event(ev, attrs)
	if type(ev) == 'string' then
		local out = copy_table(attrs)
		out.kind = ev
		return out
	end
	if type(ev) ~= 'table' then
		error('service_events: event table or kind string required', 3)
	end
	local out = copy_table(ev)
	for k, v in pairs(attrs or {}) do
		if out[k] == nil then out[k] = v end
	end
	return out
end

function Port:event(ev, attrs)
	local out = normalise_event(ev, attrs)
	for k, v in pairs(self._identity or {}) do
		if out[k] == nil then out[k] = v end
	end
	if self._mark_route_events then
		out._service_event = true
	end
	return out
end

function Port:emit_now(ev, attrs)
	return queue.try_admit_now(self._tx, self:event(ev, attrs))
end

function Port:emit_required(ev, attrs, label)
	if type(attrs) == 'string' and label == nil then
		label = attrs
		attrs = nil
	end
	return queue.try_admit_required(
		self._tx,
		self:event(ev, attrs),
		label or self._label or 'service_event_admission_failed'
	)
end

function Port:assert_emit_required(ev, attrs, label)
	local ok, err = self:emit_required(ev, attrs, label)
	if ok ~= true then error(err or 'service_event_admission_failed', 2) end
	return true
end

function Port:tx()
	return self._tx
end

function Port:identity()
	return copy_table(self._identity)
end

function M.port(tx, identity, opts)
	if tx == nil or type(tx.send_op) ~= 'function' then
		error('service_events.port: mailbox tx required', 2)
	end
	opts = opts or {}
	return setmetatable({
		_tx = tx,
		_identity = copy_table(identity),
		_label = opts.label,
		_mark_route_events = not not opts.mark_route_events,
	}, Port)
end


function M.wrap(target, identity, opts)
	if target == nil then
		error('service_events.wrap: target required', 2)
	end
	if type(target.emit_required) == 'function' then
		opts = opts or {}
		return setmetatable({
			_target = target,
			_identity = copy_table(identity),
			_label = opts.label,
			_mark_route_events = not not opts.mark_route_events,
		}, TargetPort)
	end
	return M.port(target, identity, opts)
end

function M.reporter_for(target, identity, opts)
	return M.reporter(M.wrap(target, identity, opts), opts and opts.label)
end

function M.reporter(port, label)
	if type(port) ~= 'table' or type(port.emit_required) ~= 'function' then
		error('service_events.reporter: port required', 2)
	end
	return function (ev)
		return port:emit_required(ev, label or 'service_event_report_failed')
	end
end

function M.is_route_event(ev)
	return type(ev) == 'table' and ev._service_event == true
end

M.Port = Port
M.TargetPort = TargetPort

return M
