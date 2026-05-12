-- services/ui/sessions.lua
--
-- Immediate in-memory session store.
--
-- Session mutations are versioned with a Pulse.  Observers should use
-- changed_op(seen) and recompute from the current snapshot/count.

local ok_uuid, uuid = pcall(require, 'uuid')
local pulse = require 'fibers.pulse'
local tablex = require 'shared.table'

local M = {}
local Store = {}
Store.__index = Store

local function default_now()
	local ok, fibers = pcall(require, 'fibers')
	if ok and fibers and type(fibers.now) == 'function' then
		return fibers.now()
	end
	return os.time()
end

local function new_id()
	if ok_uuid and uuid and type(uuid.new) == 'function' then
		return tostring(uuid.new())
	end
	return ('sess-%d-%d'):format(os.time(), math.random(1, 1000000000))
end

local shallow_copy = tablex.shallow_copy
local copy_array = tablex.array_copy

local function copy_event(ev)
	if type(ev) ~= 'table' then return ev end
	local out = {}
	for k, v in pairs(ev) do
		if type(v) == 'table' then
			if k == 'session_ids' then
				out[k] = copy_array(v)
			elseif k == 'sessions' then
				local arr = {}
				for i = 1, #v do arr[i] = shallow_copy(v[i]) end
				out[k] = arr
			else
				out[k] = shallow_copy(v)
			end
		else
			out[k] = v
		end
	end
	return out
end

local function public_view(rec)
	if not rec then return nil end
	return {
		id         = rec.id,
		principal  = rec.principal,
		created_at = rec.created_at,
		expires_at = rec.expires_at,
		last_seen  = rec.last_seen,
		data       = shallow_copy(rec.data),
	}
end

local function is_expired(self, rec, now)
	if not rec then return false end
	now = now or self:now()
	return rec.expires_at ~= nil and rec.expires_at <= now
end

function M.new(opts)
	opts = opts or {}
	return setmetatable({
		_items = {},
		_now = opts.now or default_now,
		_default_ttl = opts.default_ttl or 3600,
		_pulse = pulse.new(),
		_last_event = nil,
	}, Store)
end

function Store:_notify(ev)
	if type(ev) ~= 'table' then ev = { kind = tostring(ev) } end
	ev.count = self:count()
	self._last_event = copy_event(ev)
	self._pulse:signal()
	return true, nil
end

function Store:version()
	return self._pulse:version()
end

function Store:last_event()
	return copy_event(self._last_event)
end


function Store:snapshot()
	return {
		version = self:version(),
		count = self:count(),
		sessions = self:list(),
		last_event = self:last_event(),
	}
end

function Store:changed_op(seen)
	return self._pulse:changed_op(seen):wrap(function (version, reason)
		if version == nil then
			return nil, nil, reason
		end
		return version, self:snapshot(), nil
	end)
end

function Store:now()
	return self._now()
end

function Store:create(principal, opts)
	opts = opts or {}
	local now = self:now()
	local ttl = opts.ttl or self._default_ttl
	local id = opts.id or new_id()
	local rec = {
		id = id,
		principal = principal,
		created_at = now,
		last_seen = now,
		expires_at = now + ttl,
		data = shallow_copy(opts.data),
	}
	self._items[id] = rec
	local view = public_view(rec)
	self:_notify({ kind = 'session_created', session_id = id, principal = principal, session = view })
	return view
end

function Store:get(id)
	local rec = self._items[id]
	if not rec or is_expired(self, rec) then return nil end
	return public_view(rec)
end

function Store:touch(id, opts)
	opts = opts or {}
	local rec = self._items[id]
	if not rec then return nil, 'not_found' end
	local now = self:now()
	if is_expired(self, rec, now) then
		return nil, 'expired'
	end
	rec.last_seen = now
	if opts.ttl then rec.expires_at = now + opts.ttl end
	if opts.data then rec.data = shallow_copy(opts.data) end
	local view = public_view(rec)
	self:_notify({ kind = 'session_touched', session_id = id, principal = rec.principal, session = view })
	return view, nil
end

function Store:delete(id)
	local rec = self._items[id]
	local existed = rec ~= nil
	self._items[id] = nil
	if existed then
		self:_notify({
			kind = 'session_deleted',
			session_id = id,
			principal = rec.principal,
			session = public_view(rec),
		})
	end
	return existed
end

function Store:prune(now)
	now = now or self:now()
	local removed = {}
	local removed_sessions = {}
	for id, rec in pairs(self._items) do
		if rec.expires_at and rec.expires_at <= now then
			self._items[id] = nil
			removed[#removed + 1] = id
			removed_sessions[#removed_sessions + 1] = public_view(rec)
		end
	end
	table.sort(removed, function (a, b) return tostring(a) < tostring(b) end)
	if #removed > 0 then
		self:_notify({
			kind = 'session_pruned',
			session_ids = copy_array(removed),
			sessions = removed_sessions,
			removed = #removed,
		})
	end
	return removed
end

function Store:count()
	local n = 0
	local now = self:now()
	for _, rec in pairs(self._items) do
		if not is_expired(self, rec, now) then n = n + 1 end
	end
	return n
end

function Store:list()
	local out = {}
	local now = self:now()
	for _, rec in pairs(self._items) do
		if not is_expired(self, rec, now) then
			out[#out + 1] = public_view(rec)
		end
	end
	table.sort(out, function(a, b) return tostring(a.id) < tostring(b.id) end)
	return out
end

function Store:public_view(id)
	return self:get(id)
end

M.Store = Store
return M
