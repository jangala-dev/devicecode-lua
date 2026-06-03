-- bus.lua
--
-- Simple in-process bus built on fibers + trie.
--
-- Public planes:
--   * state/event plane : publish, retain, unretain, subscribe, watch_retained
--   * command plane     : bind, call
--
-- Key properties:
--   * wildcard subscriptions (pubsub trie: wildcards allowed in stored keys; literal queries)
--   * retained messages (retained trie: literal stored keys; wildcards allowed in queries)
--   * retained watch feeds (wildcard watch patterns over retain/unretain lifecycle)
--   * retained materialised views for event-driven assertions/observation
--   * bounded endpoint calls with native request/reply (no public reply topics)
--   * immutable origin metadata attached to delivered bus objects
--   * trusted provenance is bus-owned; callers may attach only origin.extra
--   * principal-aware authorisation hooks on connection actions
---@module 'bus'

local mailbox   = require 'fibers.mailbox'
local cond      = require 'fibers.cond'
local op        = require 'fibers.op'
local performer = require 'fibers.performer'
local runtime   = require 'fibers.runtime'
local scope_mod = require 'fibers.scope'
local sleep     = require 'fibers.sleep'

local ok_probe, leak_probe = pcall(require, 'devicecode.support.leak_probe')
if not ok_probe then leak_probe = nil end

local trie = require 'trie'
local uuid = require 'uuid'

local perform = performer.perform

---@alias Topic any[]
---@alias FullPolicy '"drop_oldest"'|'"reject_newest"'

local DEFAULT_Q_LEN  = 10
local DEFAULT_POLICY = 'drop_oldest'

--------------------------------------------------------------------------------
-- trie literal helper (escape hatch)
--------------------------------------------------------------------------------

local LIT_MT = getmetatable(trie.literal('x'))

---@param tok any
---@return boolean
local function is_lit(tok)
	return type(tok) == 'table' and getmetatable(tok) == LIT_MT
end

---@param tok any
---@return any v
---@return boolean was_lit
local function unwrap_token(tok)
	if is_lit(tok) then
		return tok.v, true
	end
	return tok, false
end

--------------------------------------------------------------------------------
-- Validation / small helpers
--------------------------------------------------------------------------------

---@param p any
---@param level? integer
---@return FullPolicy|nil
local function assert_full_policy(p, level)
	level = (level or 1) + 1
	if p == nil then return nil end

	if p == 'drop_newest' then
		error('mailbox full policy "drop_newest" is deprecated; use "reject_newest"', level)
	end

	if p == 'drop_oldest' or p == 'reject_newest' then
		return p
	end

	if p == 'block' then
		error('bus delivery must be bounded; mailbox full policy "block" is not supported', level)
	end

	error('invalid mailbox full policy: ' .. tostring(p), level)
end

---@param t any
---@param errlvl integer
---@return integer n
local function array_len(t, errlvl)
	if type(t) ~= 'table' then
		error('tokens must be a table (dense array)', errlvl)
	end

	local n = 0
	for _ in ipairs(t) do n = n + 1 end

	for k in pairs(t) do
		if type(k) ~= 'number' or k < 1 or k % 1 ~= 0 or k > n then
			error('token arrays must use 1..n integer keys only', errlvl)
		end
	end

	return n
end

---@param topic any
---@param what string
---@param level? integer
---@return Topic
local function assert_topic(topic, what, level)
	level = (level or 1) + 1
	local n = array_len(topic, level)

	for i = 1, n do
		local v  = topic[i]
		local uv = unwrap_token(v)
		local tv = type(uv)
		if tv ~= 'string' and tv ~= 'number' then
			error(('%s[%d] must be a string or number (got %s)'):format(what, i, tv), level)
		end
	end

	return topic
end

---@param s_wild string|number
---@param m_wild string|number
---@param topic Topic
---@param what string
---@param level? integer
local function assert_concrete_topic(s_wild, m_wild, topic, what, level)
	level = (level or 1) + 1
	local n = array_len(topic, level)

	for i = 1, n do
		local raw, was_lit = unwrap_token(topic[i])
		if not was_lit and (raw == s_wild or raw == m_wild) then
			error(('%s must be a concrete topic (no wildcards)'):format(what), level)
		end
	end
end

---@param topic Topic
---@return string
local function topic_key(topic)
	local n = array_len(topic, 3)
	local parts = {}

	for i = 1, n do
		local raw = unwrap_token(topic[i])
		if type(raw) == 'string' then
			parts[#parts + 1] = 's' .. #raw .. ':' .. raw
		else
			local s = tostring(raw)
			parts[#parts + 1] = 'n' .. #s .. ':' .. s
		end
	end

	return table.concat(parts, '|')
end

---@param topic Topic
---@return string
local function topic_debug(topic)
	local n = array_len(topic, 3)
	local parts = {}

	for i = 1, n do
		local raw, was_lit = unwrap_token(topic[i])
		parts[i] = was_lit and ('=' .. tostring(raw)) or tostring(raw)
	end

	return table.concat(parts, '/')
end

local function copy_table(t)
	local out = {}
	if not t then return out end

	for k, v in pairs(t) do
		out[k] = v
	end

	return out
end

local function freeze_shallow(t, err)
	local data = t or {}

	return setmetatable({}, {
		__index     = data,
		__newindex  = function () error(err or 'table is immutable', 2) end,
		__pairs     = function () return next, data, nil end,
		__metatable = false,
	})
end

---@param tx MailboxTx
---@param value any
---@return boolean|nil ok
---@return string|nil reason
local function mailbox_try_send(tx, value)
	local send_op = tx:send_op(value)
	local ready, ok, reason = send_op.try_fn()

	assert(ready, 'bus mailbox unexpectedly blocked')

	if ok == true then return true, nil end
	if ok == nil then return nil, reason or 'closed' end
	return false, reason or 'full'
end

---@param tx MailboxTx
---@param value any
local function deliver_best_effort(tx, value)
	mailbox_try_send(tx, value)
end

local function deliver_required_or_close(tx, value, close_reason)
	local ok, reason = mailbox_try_send(tx, value)
	if ok == true then
		return true
	end

	tx:close(close_reason or reason or 'closed')
	return false
end

local function require_opts_table(name, opts, level)
	if opts ~= nil and type(opts) ~= 'table' then
		error(name .. ': opts must be a table (or nil)', (level or 1) + 1)
	end

	return opts or {}
end

local function resolve_queue_len(opts, default_len, name, level)
	local qlen = opts.queue_len
	if qlen == nil then qlen = default_len end

	if type(qlen) ~= 'number' or qlen < 0 then
		error(name .. ': queue_len must be >= 0', (level or 1) + 1)
	end

	return qlen
end

local function resolve_feed_opts(opts, default_len, default_full, name, level)
	opts = require_opts_table(name, opts, (level or 1) + 1)

	local qlen = resolve_queue_len(opts, default_len, name, (level or 1) + 1)
	local full = assert_full_policy(opts.full or default_full, (level or 1) + 1) or DEFAULT_POLICY

	return opts, qlen, full
end

local function count_keys(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

local function snapshot_keys(set)
	local out = {}
	for item in pairs(set) do
		out[#out + 1] = item
	end
	return out
end

local function clear_finaliser(obj)
	if obj._detach_finaliser then
		obj._detach_finaliser()
		obj._detach_finaliser = nil
	end
end

local function own_in_scope(set, obj, detach_fn)
	set[obj] = true
	if leak_probe then leak_probe.bus_feed_created(obj._kind or 'retained_view') end
	obj._detach_finaliser = scope_mod.current():finally(detach_fn)
	return obj
end

local function disconnect_all(set, f)
	for _, item in ipairs(snapshot_keys(set)) do
		f(item)
	end
end

--------------------------------------------------------------------------------
-- Origin
--------------------------------------------------------------------------------

local function trusted_origin_base(conn)
	local src = conn._origin_factory
	if type(src) == 'function' then
		src = src() or {}
	end

	return copy_table(src)
end

---@param conn Connection
---@param extra? table
---@return Origin
local function build_origin(conn, extra)
	local out = trusted_origin_base(conn)

	if out.kind == nil then out.kind = 'local' end

	out.conn_id   = conn._conn_id
	out.principal = conn._principal

	if type(extra) == 'table' and next(extra) ~= nil then
		out.extra = freeze_shallow(copy_table(extra), 'origin.extra is immutable')
	end

	return freeze_shallow(out, 'origin is immutable')
end

--------------------------------------------------------------------------------
-- Authorisation
--------------------------------------------------------------------------------

---@param auth any
---@return function|nil
local function authoriser_callable(auth)
	if auth == nil then return nil end

	if type(auth) == 'function' then
		return function(ctx)
			return auth(ctx)
		end
	end

	if type(auth) == 'table' then
		if type(auth.allow) == 'function' then
			return function(ctx)
				return auth:allow(ctx)
			end
		end

		if type(auth.authorize) == 'function' then
			return function(ctx)
				return auth:authorize(ctx)
			end
		end
	end

	return nil
end

---@param bus Bus
---@param principal any
---@param action string
---@param topic Topic
---@param extra? table
---@param level? integer
---@return boolean ok
---@return any reason
local function authorize_action(bus, principal, action, topic, extra, level)
	level = (level or 1) + 1

	local fn = bus and bus._authoriser or nil
	if fn == nil then
		return true, nil
	end

	local ok, reason = fn({
		bus       = bus,
		principal = principal,
		action    = action,
		topic     = topic,
		extra     = extra,
	})

	if ok == false or ok == nil then
		return false, reason or 'forbidden'
	end

	return true, nil
end

---@param self Connection
---@param action string
---@param topic Topic
---@param extra? table
---@param level? integer
local function assert_authorized(self, action, topic, extra, level)
	level = (level or 1) + 1

	local ok, reason = authorize_action(self._bus, self._principal, action, topic, extra, level)
	if not ok then
		error(
			('permission denied for %s on %s: %s'):format(
				tostring(action),
				topic_debug(topic),
				tostring(reason or 'forbidden')
			),
			level
		)
	end
end

--------------------------------------------------------------------------------
-- Delivered objects
--------------------------------------------------------------------------------

---@class Origin
---@field kind string
---@field conn_id string|nil
---@field principal any|nil
---@field link_id string|nil
---@field peer_node string|nil
---@field peer_sid string|nil
---@field generation integer|nil
---@field extra table|nil
local Origin = {}

---@class Message
---@field topic Topic
---@field payload any
---@field origin Origin
local Message = {}
Message.__index = Message

---@param topic Topic
---@param payload any
---@param origin Origin
---@return Message
local function new_msg(topic, payload, origin)
	return setmetatable({
		topic   = topic,
		payload = payload,
		origin  = origin,
	}, Message)
end

---@class RetainedEvent
---@field op '"retain"'|'"unretain"'|'"replay_done"'
---@field topic Topic|nil
---@field payload any|nil
---@field origin Origin|nil
local RetainedEvent = {}
RetainedEvent.__index = RetainedEvent

---@param op_name '"retain"'|'"unretain"'|'"replay_done"'
---@param topic Topic|nil
---@param payload? any
---@param origin? Origin
---@return RetainedEvent
local function new_retained_event(op_name, topic, payload, origin)
	return setmetatable({
		op      = op_name,
		topic   = topic,
		payload = payload,
		origin  = origin,
	}, RetainedEvent)
end

local BUS_ORIGIN = freeze_shallow({ kind = 'bus' }, 'origin is immutable')

local function new_replay_done_event()
	return new_retained_event('replay_done', nil, nil, BUS_ORIGIN)
end

---@class Request
---@field topic Topic
---@field payload any
---@field origin Origin
---@field _cond Cond
---@field _done boolean
---@field _status string
---@field _ok boolean|nil
---@field _value any
---@field _err any
local Request = {}
Request.__index = Request

---@param topic Topic
---@param payload any
---@param origin Origin
---@return Request
local function new_request(topic, payload, origin)
	return setmetatable({
		topic   = topic,
		payload = payload,
		origin  = origin,
		_cond   = cond.new(),
		_done   = false,
		_status = 'pending',
		_ok     = nil,
		_value  = nil,
		_err    = nil,
	}, Request)
end

---@param value any
---@return boolean ok
function Request:reply(value)
	if self._done then return false end
	if leak_probe then leak_probe.bus_call_resolved('replied') end

	self._done   = true
	self._status = 'replied'
	self._ok     = true
	self._value = value
	self._err   = nil
	self._cond:signal()

	return true
end

---@param err any
---@return boolean ok
function Request:fail(err)
	if self._done then return false end
	if leak_probe then leak_probe.bus_call_resolved('failed') end

	self._done   = true
	self._status = 'failed'
	self._ok     = false
	self._value  = nil
	self._err    = err
	self._cond:signal()

	return true
end

---@param reason? any
---@return boolean ok
function Request:abandon(reason)
	if self._done then return false end
	if leak_probe then leak_probe.bus_call_resolved('abandoned') end

	self._done   = true
	self._status = 'abandoned'
	self._ok     = false
	self._value  = nil
	self._err    = reason or 'abandoned'
	self._cond:signal()

	return true
end

---@return boolean
function Request:done()
	return self._done
end

---@return string status
---@return any value
---@return any err
function Request:status()
	return self._status or 'pending', self._value, self._err
end

---@return Op
function Request:done_op()
	if self._done then
		return op.always(self:status())
	end

	return self._cond:wait_op():wrap(function ()
		return self:status()
	end)
end

---@return Op
function Request:wait_reply_op()
	if self._done then
		if self._ok then
			return op.always(self._value, nil)
		end

		return op.always(nil, self._err)
	end

	return self._cond:wait_op():wrap(function ()
		if self._ok then
			return self._value, nil
		end

		return nil, self._err
	end)
end

--------------------------------------------------------------------------------
-- Common feed-handle behaviour
--------------------------------------------------------------------------------

---@class Feed
local Feed = {}
Feed.__index = Feed

---@class Subscription : Feed
local Subscription = {}
Subscription.__index = Subscription
setmetatable(Subscription, { __index = Feed })

---@class RetainedWatch : Feed
local RetainedWatch = {}
RetainedWatch.__index = RetainedWatch
setmetatable(RetainedWatch, { __index = Feed })

---@class Endpoint : Feed
local Endpoint = {}
Endpoint.__index = Endpoint
setmetatable(Endpoint, { __index = Feed })

local function new_feed(mt, conn, kind, topic, tx, rx, extra)
	local obj = {
		_conn             = conn,
		_kind             = kind,
		_topic            = topic,
		_tx               = tx,
		_rx               = rx,
		_closed           = cond.new(),
		_detach_finaliser = nil,
	}

	if extra then
		for k, v in pairs(extra) do obj[k] = v end
	end

	return setmetatable(obj, mt)
end

local function new_subscription(conn, topic, tx, rx)
	return new_feed(Subscription, conn, 'subscription', topic, tx, rx)
end

local function new_retained_watch(conn, topic, tx, rx)
	return new_feed(RetainedWatch, conn, 'retained_watch', topic, tx, rx)
end

local function new_endpoint(conn, topic, key, tx, rx)
	return new_feed(Endpoint, conn, 'endpoint', topic, tx, rx, { _key = key })
end

function Feed:kind()
	return self._kind
end

function Feed:topic()
	return self._topic
end

function Feed:why()
	return self._rx:why()
end

function Feed:dropped()
	local tx = self._tx
	return (tx and tx.dropped and tx:dropped()) or 0
end

---@param reason any
function Feed:_close(reason)
	if not self._probe_closed and leak_probe then
		leak_probe.bus_feed_closed(self._kind or 'feed')
		self._probe_closed = true
	end
	if self._tx then self._tx:close(reason) end
	if self._closed then self._closed:signal() end
end

---@return Op
function Feed:closed_op()
	local why = self:why()
	if why ~= nil then
		return op.always(tostring(why))
	end

	return self._closed:wait_op():wrap(function ()
		return tostring(self:why() or 'closed')
	end)
end

---@return Op
function Feed:recv_op()
	return self._rx:recv_op():wrap(function (item)
		if item == nil then
			return nil, tostring(self._rx:why() or 'closed')
		end

		return item, nil
	end)
end

function Feed:recv()
	return perform(self:recv_op())
end

function Feed:iter()
	return self._rx:iter()
end

function Feed:payloads()
	if getmetatable(self) ~= Subscription then
		error('payloads expects a Subscription', 2)
	end

	local it = self._rx:iter()
	return function ()
		local msg = it()
		return msg and msg.payload or nil
	end
end

function Feed:stats()
	return {
		dropped = self:dropped(),
		topic   = self._topic,
		kind    = self._kind,
	}
end

function Feed:close()
	local conn = self._conn
	if not conn then
		self:_close(self._kind == 'endpoint' and 'unbound' or 'closed')
		return true
	end

	if getmetatable(self) == Subscription then
		return conn:unsubscribe(self)
	elseif getmetatable(self) == RetainedWatch then
		return conn:unwatch_retained(self)
	elseif getmetatable(self) == Endpoint then
		return conn:unbind(self)
	end

	error('unknown feed kind: ' .. tostring(self._kind), 2)
end

function Feed:unsubscribe()
	if getmetatable(self) ~= Subscription then
		error('unsubscribe expects a Subscription', 2)
	end

	return self:close()
end

function Feed:unwatch()
	if getmetatable(self) ~= RetainedWatch then
		error('unwatch expects a RetainedWatch', 2)
	end

	return self:close()
end

function Feed:unbind()
	if getmetatable(self) ~= Endpoint then
		error('unbind expects an Endpoint', 2)
	end

	return self:close()
end

--------------------------------------------------------------------------------
-- Retained materialised view
--------------------------------------------------------------------------------

---@class RetainedView
---@field _conn Connection|nil
---@field _bus Bus|nil
---@field _topic Topic
---@field _items table<string, Message>
---@field _version integer
---@field _changed Cond
---@field _closed Cond
---@field _closed_reason any
---@field _detach_finaliser function|nil
local RetainedView = {}
RetainedView.__index = RetainedView

local function new_retained_view(conn, topic)
	return setmetatable({
		_conn             = conn,
		_bus              = conn._bus,
		_topic            = topic,
		_items            = {},
		_version          = 0,
		_changed          = cond.new(),
		_closed           = cond.new(),
		_closed_reason    = nil,
		_detach_finaliser = nil,
	}, RetainedView)
end

function RetainedView:version()
	return self._version
end

local function retained_view_bump(self)
	self._version = self._version + 1
	self._changed:signal()
	self._changed = cond.new()
end

local function retained_view_set_msg(self, msg)
  local key = topic_key(msg.topic)
  self._items[key] = new_msg(msg.topic, msg.payload, msg.origin)
  retained_view_bump(self)
end

local function retained_view_delete_topic(self, topic)
	local key = topic_key(topic)

	if self._items[key] == nil then
		return
	end

	self._items[key] = nil
	retained_view_bump(self)
end

function RetainedView:_ingest(ev)
	if self._closed_reason ~= nil then
		return
	end

	if ev.op == 'retain' then
		retained_view_set_msg(self, {
			topic   = ev.topic,
			payload = ev.payload,
			origin  = ev.origin,
		})
	elseif ev.op == 'unretain' then
		retained_view_delete_topic(self, ev.topic)
	elseif ev.op == 'replay_done' then
		-- Materialised views are kept directly by the bus. Replay markers are
		-- feed-only events and do not affect the view.
	else
		-- Future-proof: ignore unknown retained lifecycle events.
	end
end

function RetainedView:_close(reason)
	if self._closed_reason ~= nil then return end

	if leak_probe then leak_probe.bus_feed_closed('retained_view') end
	self._closed_reason = reason or 'closed'

	local bus = self._bus
	self._bus = nil

	if bus then
		bus:_remove_retained_view(self)
	end

	local conn = self._conn
	self._conn = nil

	if conn and conn._views then
		conn._views[self] = nil
	end

	clear_finaliser(self)

	retained_view_bump(self)
	self._closed:signal()
end

function RetainedView:close()
	self:_close('closed')
	return true
end

function RetainedView:closed_op()
	if self._closed_reason ~= nil then
		return op.always(tostring(self._closed_reason))
	end

	return self._closed:wait_op():wrap(function ()
		return tostring(self._closed_reason or 'closed')
	end)
end

--- Wait until the retained view changes from last_seen, or closes.
---
--- Return shape:
---   changed: version, nil
---   closed : nil, reason
---@param last_seen integer
---@return Op
function RetainedView:changed_op(last_seen)
	if type(last_seen) ~= 'number' or last_seen % 1 ~= 0 then
		error('retained_view.changed_op: last_seen must be an integer', 2)
	end

	local function close_reason()
		if self._closed_reason ~= nil then
			return tostring(self._closed_reason)
		end
		return nil
	end

	local why = close_reason()
	if why ~= nil then
		return op.always(nil, why)
	end

	if self._version > last_seen then
		return op.always(self._version, nil)
	end

	return self._changed:wait_op():wrap(function ()
		local reason = close_reason()
		if reason ~= nil then
			return nil, reason
		end

		return self._version, nil
	end)
end

local function copy_msg(msg)
	if not msg then return nil end
	return new_msg(msg.topic, msg.payload, msg.origin)
end

function RetainedView:get(topic)
  assert_topic(topic, 'topic', 2)
  local bus = self._bus or (self._conn and self._conn._bus)
  if bus then
    assert_concrete_topic(bus._s_wild, bus._m_wild, topic, 'retained_view:get topic', 2)
  end
  return copy_msg(self._items[topic_key(topic)])
end

function RetainedView:snapshot()
	local out = {}

	for _, msg in pairs(self._items) do
		out[#out + 1] = copy_msg(msg)
	end

	table.sort(out, function (a, b)
		return topic_key(a.topic) < topic_key(b.topic)
	end)

	return out
end

function RetainedView:items()
	return self:snapshot()
end

--------------------------------------------------------------------------------
-- Bus
--------------------------------------------------------------------------------

---@class Bus
---@field _q_length integer
---@field _full FullPolicy
---@field _topics any
---@field _retained any
---@field _retained_watchers any
---@field _retained_views any
---@field _conns table<Connection, boolean>
---@field _s_wild string|number
---@field _m_wild string|number
---@field _endpoints table<string, Endpoint>
---@field _authoriser function|nil
local Bus = {}
Bus.__index = Bus

---@param conn Connection
---@param topic Topic
---@param qlen integer
---@param full FullPolicy
---@return Subscription
function Bus:_subscribe(conn, topic, qlen, full)
	local subs = self._topics:retrieve(topic)
	if not subs then
		subs = {}
		self._topics:insert(topic, subs)
	end

	local tx, rx = mailbox.new(qlen, { full = full })
	local sub    = new_subscription(conn, topic, tx, rx)
	subs[sub]    = true

	self._retained:each(topic, function (_k, retained_msg)
		deliver_best_effort(tx, retained_msg)
	end)

	return sub
end

function Bus:_unsubscribe(sub)
	local subs = self._topics:retrieve(sub._topic)
	if not subs then return end

	subs[sub] = nil

	if next(subs) == nil then
		self._topics:delete(sub._topic)
	end
end

function Bus:_publish(msg)
	self._topics:each(msg.topic, function (_k, subs)
		for sub in pairs(subs) do
			if sub and sub._tx then
				deliver_best_effort(sub._tx, msg)
			end
		end
	end)
end

function Bus:_notify_retained(ev)
	self._retained_watchers:each(ev.topic, function (_k, watchers)
		for rw in pairs(watchers) do
			if rw and rw._tx then
				deliver_best_effort(rw._tx, ev)
			end
		end
	end)
end

function Bus:_add_retained_view(view)
	local views = self._retained_views:retrieve(view._topic)
	if not views then
		views = {}
		self._retained_views:insert(view._topic, views)
	end

	views[view] = true

	self._retained:each(view._topic, function (_k, retained_msg)
		retained_view_set_msg(view, retained_msg)
	end)
end

function Bus:_remove_retained_view(view)
	local views = self._retained_views:retrieve(view._topic)
	if not views then return end

	views[view] = nil

	if next(views) == nil then
		self._retained_views:delete(view._topic)
	end
end

function Bus:_notify_retained_views(ev)
	self._retained_views:each(ev.topic, function (_k, views)
		for view in pairs(views) do
			view:_ingest(ev)
		end
	end)
end

function Bus:_retain(msg)
	self:_publish(msg)
	self._retained:insert(msg.topic, msg)
	if leak_probe then leak_probe.bus_retained(self._probe_id, topic_key(msg.topic), topic_debug(msg.topic)) end

	local ev = new_retained_event('retain', msg.topic, msg.payload, msg.origin)
	self:_notify_retained(ev)
	self:_notify_retained_views(ev)
end

function Bus:_unretain(topic, origin)
	self._retained:delete(topic)
	if leak_probe then leak_probe.bus_unretained(self._probe_id, topic_key(topic)) end

	local ev = new_retained_event('unretain', topic, nil, origin)
	self:_notify_retained(ev)
	self:_notify_retained_views(ev)
end

---@param conn Connection
---@param topic Topic
---@param qlen integer
---@param full FullPolicy
---@param replay boolean
---@return RetainedWatch
function Bus:_watch_retained(conn, topic, qlen, full, replay)
	local watchers = self._retained_watchers:retrieve(topic)
	if not watchers then
		watchers = {}
		self._retained_watchers:insert(topic, watchers)
	end

	local tx, rx = mailbox.new(qlen, { full = full })
	local rw     = new_retained_watch(conn, topic, tx, rx)
	watchers[rw] = true

	if replay then
		self._retained:each(topic, function (_k, retained_msg)
			deliver_best_effort(tx,
				new_retained_event('retain', retained_msg.topic, retained_msg.payload, retained_msg.origin))
		end)

		if not deliver_required_or_close(tx, new_replay_done_event(), 'replay_overflow') then
			rw:_close('replay_overflow')
			watchers[rw] = nil

			if next(watchers) == nil then
				self._retained_watchers:delete(topic)
			end
		end
	end

	return rw
end

function Bus:_unwatch_retained(rw)
	local watchers = self._retained_watchers:retrieve(rw._topic)
	if not watchers then return end

	watchers[rw] = nil

	if next(watchers) == nil then
		self._retained_watchers:delete(rw._topic)
	end
end

--------------------------------------------------------------------------------
-- Connection
--------------------------------------------------------------------------------

---@class Connection
---@field _bus Bus|nil
---@field _principal any|nil
---@field _q_length integer
---@field _full FullPolicy
---@field _subs table<Subscription, boolean>
---@field _eps table<Endpoint, boolean>
---@field _rws table<RetainedWatch, boolean>
---@field _views table<RetainedView, boolean>
---@field _detach_finaliser function|nil
---@field _disconnected boolean
---@field _conn_id string
---@field _origin_factory table|fun():table
local Connection = {}
Connection.__index = Connection

local function assert_connected(self, level)
	if self._disconnected or not self._bus then
		error('connection is disconnected', (level or 1) + 1)
	end
end

local function new_connection(bus, principal, q_length, full, origin_factory)
	return setmetatable({
		_bus            = bus,
		_principal      = principal,
		_q_length       = q_length,
		_full           = full,
		_subs           = {},
		_eps            = {},
		_rws            = {},
		_views          = {},
		_detach_finaliser = nil,
		_disconnected   = false,
		_conn_id        = tostring(uuid.new()),
		_origin_factory = origin_factory or {},
	}, Connection)
end

function Connection:is_disconnected()
	return self._disconnected
end

function Connection:principal()
	return self._principal
end

---@param opts? { principal?: any, origin_factory?: table|fun():table, origin_base?: table|fun():table }
---@return Connection
function Connection:derive(opts)
	assert_connected(self, 1)

	opts = require_opts_table('derive', opts, 2)

	local bus = assert(self._bus)
	if opts.principal == nil then
		opts.principal = self._principal
	end

	return bus:connect(opts)
end

function Connection:dropped()
	local n = 0

	for _, set in ipairs({ self._subs, self._eps, self._rws }) do
		for item in pairs(set) do
			n = n + (item:dropped() or 0)
		end
	end

	return n
end

function Connection:publish(topic, payload, opts)
	assert_connected(self, 1)
	assert_topic(topic, 'topic', 1)

	opts = require_opts_table('publish', opts, 2)

	assert_authorized(self, 'publish', topic, {
		payload = payload,
		opts    = opts,
	}, 1)

	self._bus:_publish(new_msg(topic, payload, build_origin(self, opts.extra)))
	return true
end

function Connection:retain(topic, payload, opts)
	assert_connected(self, 1)
	assert_topic(topic, 'topic', 1)

	opts = require_opts_table('retain', opts, 2)

	assert_authorized(self, 'retain', topic, {
		payload = payload,
		opts    = opts,
	}, 1)

	self._bus:_retain(new_msg(topic, payload, build_origin(self, opts.extra)))
	return true
end

function Connection:unretain(topic, opts)
	assert_connected(self, 1)
	assert_topic(topic, 'topic', 1)

	opts = require_opts_table('unretain', opts, 2)

	assert_authorized(self, 'unretain', topic, {
		opts = opts,
	}, 1)

	self._bus:_unretain(topic, build_origin(self, opts.extra))
	return true
end

---@param topic Topic
---@param opts? table
---@return Subscription
function Connection:_subscribe_internal(topic, opts)
	assert_connected(self, 1)

	local _, qlen, full = resolve_feed_opts(opts, self._q_length, self._full, '_subscribe_internal', 2)
	local sub = self._bus:_subscribe(self, topic, qlen, full)

	return own_in_scope(self._subs, sub, function ()
		sub:unsubscribe()
	end)
end

function Connection:subscribe(topic, opts)
	assert_connected(self, 1)
	assert_topic(topic, 'topic', 1)

	assert_authorized(self, 'subscribe', topic, {
		opts = opts,
	}, 1)

	return self:_subscribe_internal(topic, opts)
end

function Connection:unsubscribe(sub)
	if not sub or getmetatable(sub) ~= Subscription then
		error('unsubscribe expects a Subscription', 2)
	end

	local owned = not not self._subs[sub]

	sub:_close('unsubscribed')
	clear_finaliser(sub)

	if owned then
		self._subs[sub] = nil
		self._bus:_unsubscribe(sub)
	end

	if sub._conn == self then sub._conn = nil end

	return true
end

---@param topic Topic
---@param opts? table
---@return RetainedWatch
function Connection:_watch_retained_internal(topic, opts)
	assert_connected(self, 1)

	opts = require_opts_table('_watch_retained_internal', opts, 2)

	local _, qlen, full = resolve_feed_opts(opts, self._q_length, self._full, '_watch_retained_internal', 2)
	local replay = not not opts.replay
	local rw = self._bus:_watch_retained(self, topic, qlen, full, replay)

	return own_in_scope(self._rws, rw, function ()
		rw:unwatch()
	end)
end

function Connection:watch_retained(topic, opts)
	assert_connected(self, 1)
	assert_topic(topic, 'topic', 1)

	assert_authorized(self, 'watch_retained', topic, {
		opts = opts,
	}, 1)

	return self:_watch_retained_internal(topic, opts)
end

function Connection:unwatch_retained(rw)
	if not rw or getmetatable(rw) ~= RetainedWatch then
		error('unwatch_retained expects a RetainedWatch', 2)
	end

	local owned = not not self._rws[rw]

	rw:_close('unwatched')
	clear_finaliser(rw)

	if owned then
		self._rws[rw] = nil
		self._bus:_unwatch_retained(rw)
	end

	if rw._conn == self then rw._conn = nil end

	return true
end

---@param topic Topic
---@param opts? table
---@return RetainedView
function Connection:retained_view(topic, opts)
	assert_connected(self, 1)
	assert_topic(topic, 'topic', 1)

	opts = require_opts_table('retained_view', opts, 2)

	assert_authorized(self, 'watch_retained', topic, {
		opts = opts,
	}, 1)

	local view = new_retained_view(self, topic)
	self._bus:_add_retained_view(view)

	return own_in_scope(self._views, view, function ()
		view:_close('scope_closed')
	end)
end

---@param topic Topic
---@param opts? table
---@return Endpoint
function Connection:_bind_internal(topic, opts)
	assert_connected(self, 1)

	opts = require_opts_table('_bind_internal', opts, 2)

	local bus = assert(self._bus)
	assert_concrete_topic(bus._s_wild, bus._m_wild, topic, 'bind topic', 2)

	local qlen = resolve_queue_len(opts, 1, '_bind_internal', 2)

	local key = topic_key(topic)
	if bus._endpoints[key] ~= nil then
		error('bind: topic is already bound', 2)
	end

	local tx, rx = mailbox.new(qlen, { full = 'reject_newest' })
	local ep     = new_endpoint(self, topic, key, tx, rx)

	bus._endpoints[key] = ep

	return own_in_scope(self._eps, ep, function ()
		ep:unbind()
	end)
end

function Connection:bind(topic, opts)
	assert_connected(self, 1)
	assert_topic(topic, 'topic', 1)

	assert_authorized(self, 'bind', topic, {
		opts = opts,
	}, 1)

	return self:_bind_internal(topic, opts)
end

function Connection:unbind(ep)
	if not ep or getmetatable(ep) ~= Endpoint then
		error('unbind expects an Endpoint', 2)
	end

	local bus = self._bus

	ep:_close('unbound')
	clear_finaliser(ep)

	if self._eps[ep] then
		self._eps[ep] = nil

		if bus and bus._endpoints and bus._endpoints[ep._key] == ep then
			bus._endpoints[ep._key] = nil
		end
	end

	if ep._conn == self then ep._conn = nil end

	return true
end

local function call_result_op(req, deadline)
	if req:done() then
		return req:wait_reply_op()
	end

	if deadline == false then
		return req:wait_reply_op()
	end

	local now = runtime.now()
	if deadline <= now then
		req:abandon('timeout')
		return op.always(nil, 'timeout')
	end

	local timeout_ev = sleep.sleep_op(deadline - now):wrap(function ()
		req:abandon('timeout')
		return nil, 'timeout'
	end)

	return op.choice(req:wait_reply_op(), timeout_ev)
end

function Connection:call_op(topic, payload, opts)
	opts = require_opts_table('call_op', opts, 2)

	return op.guard(function ()
		assert_connected(self, 1)
		assert_topic(topic, 'topic', 1)

		assert_authorized(self, 'call', topic, {
			payload = payload,
			opts    = opts,
		}, 1)

		local bus = assert(self._bus)
		assert_concrete_topic(bus._s_wild, bus._m_wild, topic, 'call topic', 2)

		local key = topic_key(topic)
		local ep  = bus._endpoints[key]

		if not ep or not ep._tx then
			return op.always(nil, 'no_route')
		end

		local no_timeout = opts.timeout == false or opts.deadline == false
		local timeout    = (type(opts.timeout) == 'number') and opts.timeout or 1.0
		local deadline
		if no_timeout then
			deadline = false
		elseif type(opts.deadline) == 'number' then
			deadline = opts.deadline
		else
			deadline = runtime.now() + timeout
		end
		local req        = new_request(topic, payload, build_origin(self, opts.extra))
	if leak_probe then leak_probe.bus_call_started() end

		local ok, reason = mailbox_try_send(ep._tx, req)
		if ok ~= true then
			local err = (ok == nil) and 'closed' or (reason or 'full')
			req:abandon(err)
			return op.always(nil, err)
		end

		return call_result_op(req, deadline):on_abort(function ()
			req:abandon('aborted')
		end)
	end)
end

function Connection:call(topic, payload, opts)
	return perform(self:call_op(topic, payload, opts))
end

function Connection:disconnect()
	if self._disconnected then return true end

	if leak_probe and self._bus then leak_probe.bus_connection_closed(self._bus._probe_id) end
	clear_finaliser(self)
	self._disconnected = true

	local bus = self._bus
	self._bus = nil

	disconnect_all(self._subs, function (sub)
		sub:_close('disconnected')
		clear_finaliser(sub)

		if bus then bus:_unsubscribe(sub) end

		self._subs[sub] = nil
		if sub._conn == self then sub._conn = nil end
	end)

	disconnect_all(self._rws, function (rw)
		rw:_close('disconnected')
		clear_finaliser(rw)

		if bus then bus:_unwatch_retained(rw) end

		self._rws[rw] = nil
		if rw._conn == self then rw._conn = nil end
	end)

	disconnect_all(self._eps, function (ep)
		ep:_close('disconnected')

		if bus and bus._endpoints and bus._endpoints[ep._key] == ep then
			bus._endpoints[ep._key] = nil
		end

		clear_finaliser(ep)

		self._eps[ep] = nil
		if ep._conn == self then ep._conn = nil end
	end)

	disconnect_all(self._views, function (view)
		view:_close('disconnected')
	end)

	if bus and bus._conns then
		bus._conns[self] = nil
	end

	return true
end

function Connection:stats()
	return {
		dropped          = self:dropped(),
		subscriptions    = count_keys(self._subs),
		endpoints        = count_keys(self._eps),
		retained_watches = count_keys(self._rws),
		retained_views   = count_keys(self._views),
	}
end

--------------------------------------------------------------------------------
-- Bus public API
--------------------------------------------------------------------------------

function Bus:connect(opts)
	opts = require_opts_table('connect', opts, 2)

	local s = scope_mod.current()
	local origin_factory = opts.origin_factory or opts.origin_base
	local conn = new_connection(self, opts.principal, self._q_length, self._full, origin_factory)

	self._conns[conn] = true
	if leak_probe then leak_probe.bus_connection_created(self._probe_id) end

	conn._detach_finaliser = s:finally(function ()
		conn._detach_finaliser = nil
		conn:disconnect()
	end)

	return conn
end

function Bus:stats()
	local connections      = 0
	local dropped          = 0
	local endpoints        = 0
	local retained_watches = 0
	local retained_views   = 0

	for conn in pairs(self._conns) do
		connections      = connections + 1
		dropped          = dropped + conn:dropped()
		endpoints        = endpoints + count_keys(conn._eps or {})
		retained_watches = retained_watches + count_keys(conn._rws or {})
		retained_views   = retained_views + count_keys(conn._views or {})
	end

	return {
		connections      = connections,
		dropped          = dropped,
		queue_len        = self._q_length,
		full_policy      = self._full,
		s_wild           = self._s_wild,
		m_wild           = self._m_wild,
		retained_watches = retained_watches,
		retained_views   = retained_views,
		endpoints        = endpoints,
	}
end

--------------------------------------------------------------------------------
-- Constructor
--------------------------------------------------------------------------------

---@param params? { q_length?: integer, full?: FullPolicy, s_wild?: string|number, m_wild?: string|number, authoriser?: any }
---@return Bus
local function new(params)
	params = params or {}

	local q_length = params.q_length
	if q_length == nil then q_length = DEFAULT_Q_LEN end

	if type(q_length) ~= 'number' or q_length < 0 then
		error('bus.new: q_length must be >= 0', 2)
	end

	local full_default = assert_full_policy(params.full, 2) or DEFAULT_POLICY
	local s_wild       = params.s_wild or '+'
	local m_wild       = params.m_wild or '#'

	local authoriser = authoriser_callable(params.authoriser)
	if params.authoriser ~= nil and not authoriser then
		error('bus authoriser must be a function or table with :allow(ctx) / :authorize(ctx)', 2)
	end

	local probe_id = leak_probe and leak_probe.bus_next_id() or nil
	local b = setmetatable({
		_probe_id          = probe_id,
		_q_length          = q_length,
		_full              = full_default,
		_s_wild            = s_wild,
		_m_wild            = m_wild,
		_topics            = trie.new_pubsub(s_wild, m_wild),
		_retained          = trie.new_retained(s_wild, m_wild),
		_retained_watchers = trie.new_pubsub(s_wild, m_wild),
		_retained_views    = trie.new_pubsub(s_wild, m_wild),
		_conns             = setmetatable({}, { __mode = 'k' }),
		_endpoints         = {},
		_authoriser        = authoriser,
	}, Bus)
	if leak_probe then leak_probe.bus_created(probe_id) end
	return b
end

return {
	new = new,

	Bus           = Bus,
	Connection    = Connection,
	Subscription  = Subscription,
	RetainedWatch = RetainedWatch,
	RetainedView  = RetainedView,
	Endpoint      = Endpoint,
	Message       = Message,
	RetainedEvent = RetainedEvent,
	Request       = Request,
	Origin        = Origin,

	-- Re-export trie literal helper for convenience.
	literal = trie.literal,
}
