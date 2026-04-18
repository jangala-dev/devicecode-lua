local fibers = require 'fibers'
local op     = require 'fibers.op'
local pulse  = require 'fibers.pulse'
local cond   = require 'fibers.cond'
local sleep  = require 'fibers.sleep'
local trie   = require 'trie'

local errors = require 'services.ui.errors'
local topics = require 'services.ui.topics'

local M = {}
local Model = {}
Model.__index = Model

local DEFAULT_SOURCES = {
	{ name = 'cfg',   pattern = { 'cfg', '#' } },
	{ name = 'svc',   pattern = { 'svc', '#' } },
	{ name = 'state', pattern = { 'state', '#' } },
	{ name = 'cap',   pattern = { 'cap', '#' } },
	{ name = 'dev',   pattern = { 'dev', '#' } },
}

local function watcher_close(self, key, reason)
	local rec = self._watchers[key]
	if not rec then return false end
	self._watchers[key] = nil
	pcall(function() rec.tx:close(reason or 'closed') end)
	return true
end

local function snapshot_entry_copy(rec)
	return {
		topic = topics.copy_plain(rec.topic),
		payload = topics.copy_plain(rec.payload),
		origin = rec.origin,
		seq = rec.seq,
	}
end

function Model:is_ready()
	return self._ready == true
end

function Model:seq()
	return self._seq
end

function Model:close(reason)
	if self._closed then return true end
	self._closed = true
	self._close_reason = reason or 'closed'
	for _, rw in pairs(self._source_watches) do
		pcall(function() rw:unwatch() end)
	end
	for key in pairs(self._watchers) do
		watcher_close(self, key, self._close_reason)
	end
	self._pulse:close(self._close_reason)
	self._ready_cond:signal()
	return true
end

function Model:await_ready_op(timeout_s)
	if self._ready then
		return op.always(true, nil)
	end
	if self._closed then
		return op.always(nil, self._close_reason or 'closed')
	end

	local ready_ev = self._ready_cond:wait_op():wrap(function()
		if self._ready then return true, nil end
		return nil, self._close_reason or 'closed'
	end)

	if type(timeout_s) ~= 'number' or timeout_s <= 0 then
		return ready_ev
	end

	return op.choice(
		ready_ev,
		sleep.sleep_op(timeout_s):wrap(function()
			return nil, 'timeout'
		end)
	)
end

function Model:await_ready(timeout_s)
	return fibers.perform(self:await_ready_op(timeout_s))
end

function Model:next_change_op(last_seq, timeout_s)
	if self._closed then
		return op.always(nil, self._close_reason or 'closed')
	end
	if self._seq ~= last_seq then
		return op.always(self._seq, nil)
	end

	local change_ev = self._pulse:changed_op(last_seq)
		:wrap(function(ver, reason)
			if ver == nil then return nil, reason or self._close_reason or 'closed' end
			self._seq = math.max(self._seq, ver)
			return ver, nil
		end)

	if type(timeout_s) ~= 'number' or timeout_s <= 0 then
		return change_ev
	end

	return op.choice(
		change_ev,
		sleep.sleep_op(timeout_s):wrap(function()
			return nil, 'timeout'
		end)
	)
end

function Model:get_exact(topic)
	local norm, err = topics.normalise_topic(topic, { allow_wildcards = false, allow_numbers = true })
	if not norm then return nil, errors.bad_request(err) end
	if self._closed then return nil, errors.unavailable(self._close_reason or 'closed') end
	if not self._ready then return nil, errors.not_ready('ui model is not ready') end
	local rec = self._by_key[topics.topic_key(norm)]
	if not rec then return nil, errors.not_found('not found') end
	return snapshot_entry_copy(rec), nil
end

function Model:snapshot(pattern)
	local norm, err = topics.normalise_topic(pattern, { allow_wildcards = true, allow_numbers = true })
	if not norm then return nil, errors.bad_request(err) end
	if self._closed then return nil, errors.unavailable(self._close_reason or 'closed') end
	if not self._ready then return nil, errors.not_ready('ui model is not ready') end

	local entries = {}
	self._store:each(norm, function(_, rec)
		entries[#entries + 1] = snapshot_entry_copy(rec)
	end)
	topics.sort_entries(entries)
	return {
		seq = self._seq,
		entries = entries,
	}, nil
end

function Model:open_watch(pattern, opts)
	opts = opts or {}
	local norm, err = topics.normalise_topic(pattern, { allow_wildcards = true, allow_numbers = true })
	if not norm then return nil, errors.bad_request(err) end
	if self._closed then return nil, errors.unavailable(self._close_reason or 'closed') end
	if not self._ready then return nil, errors.not_ready('ui model is not ready') end

	local qlen = (type(opts.queue_len) == 'number' and opts.queue_len >= 0) and opts.queue_len or 128
	local mailbox = require 'fibers.mailbox'
	local tx, rx = mailbox.new(qlen, { full = 'reject_newest' })
	local key = {}
	self._watchers[key] = { pattern = norm, tx = tx }

	local function close(reason)
		watcher_close(self, key, reason or 'closed')
		return true
	end

	if fibers.current_scope() then
		fibers.current_scope():finally(function()
			close('scope_exit')
		end)
	end

	local snap = assert(self:snapshot(norm))
	for i = 1, #snap.entries do
		local item = {
			op = 'retain',
			phase = 'replay',
			topic = topics.copy_plain(snap.entries[i].topic),
			payload = topics.copy_plain(snap.entries[i].payload),
			origin = snap.entries[i].origin,
			seq = snap.entries[i].seq,
		}
		local ok = tx:send(item)
		if ok ~= true then
			close('snapshot_overflow')
			return nil, errors.unavailable('watch snapshot overflow')
		end
	end

	local ok = tx:send({ op = 'replay_done', seq = snap.seq })
	if ok ~= true then
		close('snapshot_overflow')
		return nil, errors.unavailable('watch snapshot overflow')
	end

	return {
		recv_op = function()
			return rx:recv_op():wrap(function(item)
				if item == nil then return nil, tostring(rx:why() or 'closed') end
				return item, nil
			end)
		end,
		recv = function(self_watch)
			return fibers.perform(self_watch:recv_op())
		end,
		close = close,
	}, nil
end

local function fanout(self, item)
	for key, rec in pairs(self._watchers) do
		if item.op ~= 'replay_done' and rec and topics.match(rec.pattern, item.topic) then
			local ok = rec.tx:send(item)
			if ok ~= true then
				watcher_close(self, key, 'overflow')
			end
		end
	end
end

local function apply_retain(self, ev)
	local topic = topics.copy_plain(ev.topic)
	local rec = {
		topic = topic,
		payload = topics.copy_plain(ev.payload),
		origin = ev.origin,
		seq = self._seq,
	}
	self._store:insert(topic, rec)
	self._by_key[topics.topic_key(topic)] = rec
	fanout(self, {
		op = 'retain',
		phase = 'live',
		topic = topics.copy_plain(topic),
		payload = topics.copy_plain(rec.payload),
		origin = rec.origin,
		seq = rec.seq,
	})
end

local function apply_unretain(self, ev)
	local topic = topics.copy_plain(ev.topic)
	self._store:delete(topic)
	self._by_key[topics.topic_key(topic)] = nil
	fanout(self, {
		op = 'unretain',
		phase = 'live',
		topic = topics.copy_plain(topic),
		origin = ev.origin,
		seq = self._seq,
	})
end

local function next_source_event_op(self)
	local arms = {}
	for i = 1, #self._sources do
		local source = self._sources[i]
		local rw = self._source_watches[source.name]
		if rw then
			arms[source.name] = rw:recv_op():wrap(function(ev, err)
				return ev, err
			end)
		end
	end
	return op.named_choice(arms)
end

local function run(self)
	while true do
		local source, ev, err = fibers.perform(next_source_event_op(self))
		if ev == nil then
			if self._closed then return end
			error(('ui model source %s closed: %s'):format(tostring(source), tostring(err or 'closed')), 0)
		end

		if ev.op == 'replay_done' then
			self._pending[source] = nil
			if not self._ready and next(self._pending) == nil then
				self._ready = true
				self._ready_cond:signal()
			end
		elseif ev.op == 'retain' or ev.op == 'unretain' then
			self._seq = self._seq + 1
			if ev.op == 'retain' then
				apply_retain(self, ev)
			else
				apply_unretain(self, ev)
			end
			self._pulse:signal()
		end
	end
end

function M.start(conn, opts)
	opts = opts or {}
	local self = setmetatable({
		_conn = assert(conn, 'ui model requires a connection'),
		_sources = opts.sources or DEFAULT_SOURCES,
		_queue_len = (type(opts.queue_len) == 'number' and opts.queue_len > 0) and opts.queue_len or 256,
		_store = trie.new_retained('+', '#'),
		_by_key = {},
		_seq = 0,
		_ready = false,
		_closed = false,
		_close_reason = nil,
		_pending = {},
		_watchers = {},
		_source_watches = {},
		_pulse = pulse.new(0),
		_ready_cond = cond.new(),
	}, Model)

	for i = 1, #self._sources do
		local source = self._sources[i]
		self._pending[source.name] = true
		self._source_watches[source.name] = self._conn:watch_retained(source.pattern, {
			queue_len = self._queue_len,
			full = 'drop_oldest',
			replay = true,
		})
	end

	fibers.spawn(function()
		run(self)
	end)

	return self
end

M.Model = Model
return M
