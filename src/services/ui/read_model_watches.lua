-- services/ui/read_model_watches.lua
--
-- Local UI read-model watch owner and fanout boundary.
--
-- This module deliberately owns bounded watch queues and replay/fanout policy.
-- The projection store remains pure in read_model_store.lua.
-- Replay is bounded by default. Callers may set max_replay/watch_max_replay
-- explicitly; max_replay=false opts out deliberately for tests/special cases.

local fibers  = require 'fibers'
local mailbox = require 'fibers.mailbox'
local queue   = require 'devicecode.support.queue'
local store_mod = require 'services.ui.read_model_store'

local M = {}

local DEFAULT_MAX_REPLAY = 32


local function resolve_max_replay(opts)
	if opts.max_replay ~= nil then return opts.max_replay end
	if opts.watch_max_replay ~= nil then return opts.watch_max_replay end
	if opts.replay_limit ~= nil then return opts.replay_limit end
	return DEFAULT_MAX_REPLAY
end

local WatchOwner = {}
WatchOwner.__index = WatchOwner

local Watch = {}
Watch.__index = Watch

local function copy_value(v)
	return store_mod.copy_value(v)
end

local function topic_copy(topic)
	return store_mod.topic_copy(topic)
end

local function msg_event(op_name, msg)
	return {
		kind    = 'read_model_event',
		op      = op_name,
		topic   = msg and topic_copy(msg.topic) or nil,
		payload = msg and copy_value(msg.payload) or nil,
		origin  = msg and copy_value(msg.origin) or nil,
	}
end

local function terminate_watch(watch, reason)
	if watch._closed then return true end
	watch._closed = true
	watch._reason = reason or 'closed'
	if watch._tx then watch._tx:close(watch._reason) end
	if watch._owner then
		watch._owner._watches[watch] = nil
	end
	watch._owner = nil
	return true
end

local function terminate_all(owner, reason)
	local pending = {}
	for watch in pairs(owner._watches) do pending[#pending + 1] = watch end
	for _, watch in ipairs(pending) do terminate_watch(watch, reason) end
end

function WatchOwner:store()
	return self._store
end

function WatchOwner:watch_count()
	local n = 0
	for _ in pairs(self._watches) do n = n + 1 end
	return n
end

function WatchOwner:notify(op_name, msg)
	if self._closed then return nil, tostring(self._reason or 'closed') end
	if not msg or type(msg.topic) ~= 'table' then return false, 'no_topic' end

	local targets = {}
	for watch in pairs(self._watches) do
		if store_mod.match_topic(watch._pattern, msg.topic, self._s_wild, self._m_wild) then
			targets[#targets + 1] = watch
		end
	end

	local ev = msg_event(op_name, msg)
	for _, watch in ipairs(targets) do
		if watch._owner == self and not watch._closed then
			local ok = queue.try_admit_now(watch._tx, copy_value(ev))
			if ok ~= true then
				terminate_watch(watch, 'watch_overflow')
			end
		end
	end
	return true, nil
end

function WatchOwner:set(topic, payload, origin)
	local changed, msg, version_or_reason = self._store:set(topic, payload, origin)
	if changed == true then self:notify('set', msg) end
	return changed, msg, version_or_reason
end

function WatchOwner:delete(topic, origin)
	local changed, msg, version_or_reason = self._store:delete(topic, origin)
	if changed == true then self:notify('delete', msg) end
	return changed, msg, version_or_reason
end

function WatchOwner:ingest(ev)
	local changed, msg, op_name, version_or_reason = self._store:ingest(ev)
	if changed == true and (op_name == 'set' or op_name == 'delete') then
		self:notify(op_name, msg)
	end
	return changed, msg, op_name, version_or_reason
end

function WatchOwner:watch_open(pattern, opts)
	opts = opts or {}
	if self._closed then return nil, tostring(self._reason or 'closed') end
	if self._store:is_closed() then return nil, tostring(self._store:why() or 'closed') end

	local qlen = opts.queue_len or self._default_queue_len
	local full = opts.full or self._default_full
	local tx, rx = mailbox.new(qlen, { full = full })
	local watch = setmetatable({
		_owner = self,
		_pattern = topic_copy(pattern),
		_tx = tx,
		_rx = rx,
		_closed = false,
		_reason = nil,
	}, Watch)

	if opts.replay ~= false then
		local max_replay = opts.max_replay
		if max_replay == nil then max_replay = self._max_replay end
		local replay, qerr = self._store:query_limited(pattern, max_replay)
		if not replay then
			terminate_watch(watch, 'watch_replay_overflow')
			return nil, (qerr == 'query_limit_exceeded') and 'watch_replay_overflow' or qerr
		end
		for _, msg in ipairs(replay) do
			local ok = queue.try_admit_now(tx, msg_event('set', msg))
			if ok ~= true then
				terminate_watch(watch, 'watch_replay_overflow')
				return nil, 'watch_replay_overflow'
			end
		end
	end

	self._watches[watch] = true
	return watch, nil
end

function WatchOwner:terminate(reason)
	if self._closed then return true end
	self._closed = true
	self._reason = reason or 'closed'
	terminate_all(self, self._reason)
	return true
end

function WatchOwner:why()
	return self._reason
end

function Watch:recv_op()
	return self._rx:recv_op():wrap(function (ev)
		if ev == nil then
			return nil, tostring(self._reason or self._rx:why() or 'closed')
		end
		return ev, nil
	end)
end

function Watch:recv()
	return fibers.perform(self:recv_op())
end

function Watch:terminate(reason)
	return terminate_watch(self, reason or 'closed')
end

function Watch:why()
	return self._reason or self._rx:why()
end

function Watch:pattern()
	return topic_copy(self._pattern)
end

function M.new(store, opts)
	if store == nil then error('read_model_watches.new: store required', 2) end
	opts = opts or {}
	return setmetatable({
		_store = store,
		_watches = {},
		_closed = false,
		_reason = nil,
		_s_wild = opts.s_wild or '+',
		_m_wild = opts.m_wild or '#',
		_default_queue_len = opts.queue_len or opts.watch_queue_len or 32,
		_default_full = opts.full or opts.watch_full or 'reject_newest',
		_max_replay = resolve_max_replay(opts),
	}, WatchOwner)
end

M.DEFAULT_MAX_REPLAY = DEFAULT_MAX_REPLAY
M.WatchOwner = WatchOwner
M.Watch = Watch
M.msg_event = msg_event

return M
