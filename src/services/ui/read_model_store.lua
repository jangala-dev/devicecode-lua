-- services/ui/read_model_store.lua
--
-- Pure retained-state projection store for UI.
--
-- Contract:
--   * stores retained messages by literal topic key
--   * snapshot(), items(), get(), and query() return copies
--   * set/delete/ingest are immediate and non-yielding
--   * changed_op(seen) returns a versioned snapshot, or a close reason
--   * terminate(reason) wakes observers
--   * no queue, mailbox, bus, publish, or service calls live here

local op     = require 'fibers.op'
local cond   = require 'fibers.cond'
local topics = require 'services.ui.topics'
local tablex = require 'shared.table'
local topicx = require 'shared.topic'

local M = {}

local Store = {}
Store.__index = Store

local copy_value = tablex.deep_copy
local deep_equal = tablex.deep_equal
local topic_copy = topicx.copy

local function copy_msg(msg)
	if not msg then return nil end
	return {
		topic   = topic_copy(msg.topic),
		payload = copy_value(msg.payload),
		origin  = copy_value(msg.origin),
	}
end

local function token_matches(pattern_tok, topic_tok, s_wild, m_wild)
	if pattern_tok == s_wild then return true end
	if pattern_tok == m_wild then return true end
	return pattern_tok == topic_tok
end

local function match_topic(pattern, topic, s_wild, m_wild)
	pattern = pattern or {}
	topic = topic or {}
	local pi, ti = 1, 1
	while pi <= #pattern do
		local p = pattern[pi]
		if p == m_wild then
			return true
		end
		if ti > #topic then return false end
		if not token_matches(p, topic[ti], s_wild, m_wild) then
			return false
		end
		pi = pi + 1
		ti = ti + 1
	end
	return ti > #topic
end

local function index_token_key(tok)
	local ty = type(tok)
	return ty .. ':' .. tostring(tok)
end

local function first_literal_token(pattern, s_wild, m_wild)
	local tok = pattern and pattern[1] or nil
	if tok == nil or tok == s_wild or tok == m_wild then return nil end
	return tok
end

local function sorted_msgs_from_keys(self, keys, pattern)
	local out = {}
	for _, key in ipairs(keys) do
		local msg = self._items[key]
		if msg and match_topic(pattern, msg.topic, self._s_wild, self._m_wild) then
			out[#out + 1] = copy_msg(msg)
		end
	end
	table.sort(out, function(a, b)
		return topics.topic_key(a.topic) < topics.topic_key(b.topic)
	end)
	return out
end

local function assert_topic(topic, name, level)
	if type(topic) ~= 'table' then
		error((name or 'topic') .. ' must be a table', (level or 1) + 1)
	end
end

local function assert_seen(seen, level)
	if type(seen) ~= 'number' or seen < 0 or seen % 1 ~= 0 then
		error('read_model_store.changed_op: seen must be a non-negative integer', (level or 1) + 1)
	end
end

function Store:version()
	return self._version
end

function Store:is_closed()
	return self._closed
end

function Store:why()
	return self._close_reason
end

function Store:_bump()
	self._version = self._version + 1
	self._changed:signal()
	self._changed = cond.new()
	return self._version
end

function Store:_index_add(key, topic)
	local first = topic and topic[1]
	if first == nil then return end
	local ikey = index_token_key(first)
	local bucket = self._index_first[ikey]
	if not bucket then
		bucket = {}
		self._index_first[ikey] = bucket
	end
	bucket[key] = true
end

function Store:_index_remove(key, topic)
	local first = topic and topic[1]
	if first == nil then return end
	local ikey = index_token_key(first)
	local bucket = self._index_first[ikey]
	if not bucket then return end
	bucket[key] = nil
	if next(bucket) == nil then self._index_first[ikey] = nil end
end

function Store:_candidate_keys(pattern)
	local literal = first_literal_token(pattern, self._s_wild, self._m_wild)
	local out = {}
	if literal ~= nil then
		local bucket = self._index_first[index_token_key(literal)] or {}
		for key in pairs(bucket) do out[#out + 1] = key end
	else
		for key in pairs(self._items) do out[#out + 1] = key end
	end
	table.sort(out)
	return out
end

--- Set a retained item.
---
--- Return shapes:
---   true, msg, version   changed
---   false, msg, version  unchanged
---   nil, reason          closed
function Store:set(topic, payload, origin)
	assert_topic(topic, 'read_model_store:set topic', 2)
	if self._closed then return nil, tostring(self._close_reason or 'closed') end

	local key = topics.topic_key(topic)
	local old = self._items[key]
	local msg = {
		topic = topic_copy(topic),
		payload = copy_value(payload),
		origin = copy_value(origin),
	}

	local same = false
	if old and topics.topic_key(old.topic) == key then
		same = deep_equal(old.payload, msg.payload) and deep_equal(old.origin, msg.origin)
	end

	if old then self:_index_remove(key, old.topic) end
	self._items[key] = msg
	self:_index_add(key, msg.topic)
	if same then
		return false, copy_msg(msg), self._version
	end

	local version = self:_bump()
	return true, copy_msg(msg), version
end

--- Delete a retained item.
---
--- Return shapes:
---   true, msg, version   changed
---   false, nil, version  unchanged / absent
---   nil, reason          closed
function Store:delete(topic, origin)
	assert_topic(topic, 'read_model_store:delete topic', 2)
	if self._closed then return nil, tostring(self._close_reason or 'closed') end

	local key = topics.topic_key(topic)
	local old = self._items[key]
	if old == nil then return false, nil, self._version end

	self._items[key] = nil
	self:_index_remove(key, old.topic)
	local msg = {
		topic = topic_copy(topic),
		payload = nil,
		origin = copy_value(origin),
	}
	local version = self:_bump()
	return true, copy_msg(msg), version
end

--- Ingest a retained lifecycle event.
---
--- Return shapes:
---   changed, msg, op_name, version_or_reason
---   nil, nil, nil, reason     invalid/closed
function Store:ingest(ev)
	if self._closed then return nil, nil, nil, tostring(self._close_reason or 'closed') end
	if type(ev) ~= 'table' then return nil, nil, nil, 'invalid retained event' end

	if ev.op == 'retain' then
		local changed, msg, version_or_reason = self:set(ev.topic, ev.payload, ev.origin)
		if changed == nil then return nil, nil, nil, msg end
		return changed, msg, 'set', version_or_reason
	elseif ev.op == 'unretain' then
		local changed, msg, version_or_reason = self:delete(ev.topic, ev.origin)
		if changed == nil then return nil, nil, nil, msg end
		return changed, msg, 'delete', version_or_reason
	elseif ev.op == 'replay_done' then
		return false, nil, 'replay_done', self._version
	elseif ev.topic ~= nil and ev.payload ~= nil then
		local changed, msg, version_or_reason = self:set(ev.topic, ev.payload, ev.origin)
		if changed == nil then return nil, nil, nil, msg end
		return changed, msg, 'set', version_or_reason
	end

	return nil, nil, nil, 'unknown retained event'
end

function Store:snapshot()
	local out = {}
	for key, msg in pairs(self._items) do
		out[key] = copy_msg(msg)
	end
	return {
		version = self._version,
		items = out,
		closed = self._closed,
		reason = self._close_reason,
	}
end

function Store:items()
	local out = {}
	for _, msg in pairs(self._items) do out[#out + 1] = copy_msg(msg) end
	table.sort(out, function(a, b)
		return topics.topic_key(a.topic) < topics.topic_key(b.topic)
	end)
	return out
end

function Store:get(topic)
	assert_topic(topic, 'read_model_store:get topic', 2)
	return copy_msg(self._items[topics.topic_key(topic)])
end

function Store:query(pattern)
	return sorted_msgs_from_keys(self, self:_candidate_keys(pattern), pattern)
end

local function each_candidate_key_unsorted(self, pattern, fn)
	local literal = first_literal_token(pattern, self._s_wild, self._m_wild)
	if literal ~= nil then
		local bucket = self._index_first[index_token_key(literal)] or {}
		for key in pairs(bucket) do
			if fn(key) == false then return false end
		end
		return true
	end

	for key in pairs(self._items) do
		if fn(key) == false then return false end
	end
	return true
end

function Store:count(pattern)
	if pattern == nil then
		local n = 0
		for _ in pairs(self._items) do n = n + 1 end
		return n
	end

	local n = 0
	each_candidate_key_unsorted(self, pattern, function (key)
		local msg = self._items[key]
		if msg and match_topic(pattern, msg.topic, self._s_wild, self._m_wild) then
			n = n + 1
		end
		return true
	end)
	return n
end

function Store:query_limited(pattern, limit)
	if limit ~= false and limit ~= nil then
		if type(limit) ~= 'number' or limit < 0 or limit % 1 ~= 0 then
			error('read_model_store:query_limited limit must be a non-negative integer, nil, or false', 2)
		end
	end

	if limit == false or limit == nil then
		return self:query(pattern), nil
	end

	local out = {}
	local exceeded = false
	-- Work is bounded by the first limit + 1 matching retained entries.  We do
	-- not materialise or sort a broader replay before reporting overflow.
	each_candidate_key_unsorted(self, pattern, function (key)
		local msg = self._items[key]
		if msg and match_topic(pattern, msg.topic, self._s_wild, self._m_wild) then
			if #out >= limit then
				exceeded = true
				return false
			end
			out[#out + 1] = copy_msg(msg)
		end
		return true
	end)

	if exceeded then
		return nil, 'query_limit_exceeded'
	end

	table.sort(out, function(a, b)
		return topics.topic_key(a.topic) < topics.topic_key(b.topic)
	end)
	return out, nil
end

--- Wait until version > seen, or until closed.
---
--- Return shapes:
---   changed: version, snapshot, nil
---   closed : nil, nil, reason
function Store:changed_op(seen)
	assert_seen(seen, 2)

	return op.guard(function ()
		if self._closed then
			return op.always(nil, nil, tostring(self._close_reason or 'closed'))
		end
		if self._version > seen then
			return op.always(self._version, self:snapshot(), nil)
		end
		local c = self._changed
		return c:wait_op():wrap(function ()
			if self._closed then
				return nil, nil, tostring(self._close_reason or 'closed')
			end
			return self._version, self:snapshot(), nil
		end)
	end)
end

--- Wait until version > seen, returning only the version.
---
--- This is for service coordinators that only need to know that the model
--- changed. It avoids deep-copying the complete retained projection on every
--- retained-state tick.
function Store:changed_version_op(seen)
	assert_seen(seen, 2)

	return op.guard(function ()
		if self._closed then
			return op.always(nil, tostring(self._close_reason or 'closed'))
		end
		if self._version > seen then
			return op.always(self._version, nil)
		end
		local c = self._changed
		return c:wait_op():wrap(function ()
			if self._closed then
				return nil, tostring(self._close_reason or 'closed')
			end
			return self._version, nil
		end)
	end)
end

function Store:terminate(reason)
	if self._closed then return true end
	self._closed = true
	self._close_reason = reason or 'closed'
	self:_bump()
	return true
end

function M.new(opts)
	opts = opts or {}
	return setmetatable({
		_items = {},
		_index_first = {}, -- first-token index used to bound watch replay candidate scans
		_version = 0,
		_changed = cond.new(),
		_closed = false,
		_close_reason = nil,
		_s_wild = opts.s_wild or '+',
		_m_wild = opts.m_wild or '#',
	}, Store)
end

M.Store = Store
M.copy_value = copy_value
M.topic_copy = topic_copy
M.copy_msg = copy_msg
M.match_topic = match_topic
M._test = {
	candidate_count = function (store, pattern) return #store:_candidate_keys(pattern) end,
	index_token_key = index_token_key,
}

return M
