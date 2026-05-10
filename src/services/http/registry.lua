-- services/http/registry.lua
-- HTTP handle registry.  The registry is an accounting and shutdown backstop;
-- callers own normal protocol use after handoff.
--
-- The registry is deliberately not the service reducer.  It emits identity-
-- bearing events and provides immediate, idempotent termination/removal paths.

local M = {}
local Registry = {}
Registry.__index = Registry

local function copy(t)
	local out = {}
	for k, v in pairs(t or {}) do out[k] = v end
	return out
end

local function copy_record(rec)
	return {
		kind = rec.kind,
		handle = rec.handle,
		handle_id = rec.handle_id,
		generation = rec.generation,
		owner = rec.owner,
		state = rec.state,
		listener_id = rec.listener_id,
		context_id = rec.context_id,
	}
end

local function event_for(rec, suffix, extra)
	local kind = rec.kind .. '_' .. suffix
	if rec.kind == 'context' and suffix == 'registered' then kind = 'context_admitted' end
	local ev = {
		kind = kind,
		handle_id = rec.handle_id,
		generation = rec.generation,
		listener_id = rec.listener_id,
		context_id = rec.context_id,
	}
	for k, v in pairs(extra or {}) do ev[k] = v end
	return ev
end

function M.new(opts)
	opts = opts or {}
	return setmetatable({
		_next_id = 0,
		_records = {},
		_events_port = opts.events_port,
	}, Registry)
end

function Registry:_new_id()
	while true do
		self._next_id = self._next_id + 1
		local id = 'h' .. tostring(self._next_id)
		if self._records[id] == nil then return id end
	end
end

function Registry:_emit(ev)
	local port = self._events_port
	if port and type(port.emit_required) == 'function' then
		return port:emit_required(copy(ev), 'http_registry_event_report_failed')
	end

	return true
end

local function apply_opts(rec, opts)
	rec.generation = opts.generation or rec.generation or 1
	rec.owner = opts.owner or rec.owner or 'http_service'
	if opts.listener_id ~= nil then rec.listener_id = opts.listener_id end
	if opts.context_id ~= nil then rec.context_id = opts.context_id end
	return rec
end

function Registry:reserve(kind, opts)
	opts = opts or {}
	local id = opts.id or self:_new_id()
	if self._records[id] ~= nil then return nil, 'handle_exists' end
	local rec = apply_opts({
		kind = kind,
		handle = nil,
		handle_id = id,
		state = 'reserved',
	}, opts)
	self._records[id] = rec
	return id, copy_record(rec)
end

function Registry:register(kind, handle, opts)
	opts = opts or {}
	local id = opts.id
	local rec
	if id ~= nil then
		rec = self._records[id]
		if rec ~= nil then
			if rec.kind ~= kind then return nil, 'handle_kind_mismatch' end
			if rec.state ~= 'reserved' then return nil, 'handle_not_reserved' end
		else
			rec = {
				kind = kind,
				handle_id = id,
				state = 'reserved',
			}
			self._records[id] = rec
		end
	else
		id = self:_new_id()
		rec = {
			kind = kind,
			handle_id = id,
			state = 'reserved',
		}
		self._records[id] = rec
	end

	rec.handle = handle
	apply_opts(rec, opts)
	rec.state = 'registered'
	self:_emit(event_for(rec, 'registered'))
	return id, copy_record(rec)
end

function Registry:get(id)
	return self._records[id]
end

function Registry:mark_transferred(id, generation)
	local rec = self._records[id]
	if not rec then return nil, 'stale_handle' end
	if generation ~= nil and rec.generation ~= generation then return nil, 'stale_handle' end
	if rec.state == 'terminated' then return nil, 'stale_handle' end
	if rec.owner == 'caller_after_handoff' and rec.state == 'transferred' then return true end
	rec.owner = 'caller_after_handoff'
	rec.state = 'transferred'
	self:_emit(event_for(rec, 'transferred'))
	return true
end

function Registry:remove(id, reason, generation)
	local rec = self._records[id]
	if not rec then return false, 'stale_handle' end
	if generation ~= nil and rec.generation ~= generation then return false, 'stale_handle' end
	self._records[id] = nil
	local prev_state = rec.state
	rec.state = 'terminated'
	rec.reason = reason or 'closed'
	-- Reserved-only records were never externally live.  Removing them should be
	-- idempotent cleanup, not an active-handle termination event.
	if prev_state ~= 'reserved' then
		self:_emit(event_for(rec, 'terminated', { reason = rec.reason }))
	end
	return true
end

function Registry:terminate(id, reason, generation)
	local rec = self._records[id]
	if not rec then return false, 'stale_handle' end
	if generation ~= nil and rec.generation ~= generation then return false, 'stale_handle' end
	local h = rec.handle
	if h and type(h.terminate) == 'function' then h:terminate(reason or 'http_service_shutdown') end
	return self:remove(id, reason, generation)
end

function Registry:terminate_all(reason)
	local ids = {}
	for id in pairs(self._records) do ids[#ids + 1] = id end
	for _, id in ipairs(ids) do self:terminate(id, reason or 'http_service_shutdown') end
	return true
end

function Registry:count(kind)
	local n = 0
	for _, rec in pairs(self._records) do
		if rec.state ~= 'reserved' and rec.state ~= 'terminated' and (kind == nil or rec.kind == kind) then
			n = n + 1
		end
	end
	return n
end

function Registry:snapshot()
	local out = {}
	for id, rec in pairs(self._records) do
		out[id] = {
			handle_id = rec.handle_id,
			kind = rec.kind,
			generation = rec.generation,
			owner = rec.owner,
			state = rec.state,
			listener_id = rec.listener_id,
			context_id = rec.context_id,
		}
	end
	return out
end

M.Registry = Registry
return M
