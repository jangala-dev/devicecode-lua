local cap_args = require 'services.hal.types.capability_args'

local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'
local op     = require 'fibers.op'
local wait   = require 'fibers.wait'

local perform = fibers.perform

----------------------------------------------------------------------
-- Topic helpers
----------------------------------------------------------------------

-- Legacy public capability discovery surface.
local function t_cap_listen(class, id)
	return { 'cap', class, id, 'state' }
end

local function t_cap_state(class, id, state)
	return { 'cap', class, id, 'state', state }
end

local function t_cap_event(class, id, event)
	return { 'cap', class, id, 'event', event }
end

local function t_cap_control(class, id, method)
	return { 'cap', class, id, 'rpc', method }
end

-- New curated public capability surface.
local function t_cap_meta(class, id)
	return { 'cap', class, id, 'meta' }
end

local function t_cap_status(class, id)
	return { 'cap', class, id, 'status' }
end

----------------------------------------------------------------------
-- Raw host capability surface
----------------------------------------------------------------------

local function t_raw_host_cap_meta(source, class, id)
	return { 'raw', 'host', source, 'cap', class, id, 'meta' }
end

local function t_raw_host_cap_status(source, class, id)
	return { 'raw', 'host', source, 'cap', class, id, 'status' }
end

local function t_raw_host_cap_state(source, class, id, state)
	return { 'raw', 'host', source, 'cap', class, id, 'state', state }
end

local function t_raw_host_cap_event(source, class, id, event)
	return { 'raw', 'host', source, 'cap', class, id, 'event', event }
end

local function t_raw_host_cap_control(source, class, id, method)
	return { 'raw', 'host', source, 'cap', class, id, 'rpc', method }
end

----------------------------------------------------------------------
-- Raw member capability surface
----------------------------------------------------------------------

local function t_raw_member_cap_meta(source, class, id)
	return { 'raw', 'member', source, 'cap', class, id, 'meta' }
end

local function t_raw_member_cap_status(source, class, id)
	return { 'raw', 'member', source, 'cap', class, id, 'status' }
end

local function t_raw_member_cap_state(source, class, id, state)
	return { 'raw', 'member', source, 'cap', class, id, 'state', state }
end

local function t_raw_member_cap_event(source, class, id, event)
	return { 'raw', 'member', source, 'cap', class, id, 'event', event }
end

local function t_raw_member_cap_control(source, class, id, method)
	return { 'raw', 'member', source, 'cap', class, id, 'rpc', method }
end

----------------------------------------------------------------------
-- Validation helpers
----------------------------------------------------------------------

local function assert_source(source, level)
	if type(source) ~= 'string' or source == '' then
		error('source must be a non-empty string', (level or 1) + 1)
	end
	return source
end

----------------------------------------------------------------------
-- Topic resolution helpers
----------------------------------------------------------------------

local function control_topic(self, method)
	if self.raw_kind == 'host' then
		return t_raw_host_cap_control(self.source, self.class, self.id, method)
	elseif self.raw_kind == 'member' then
		return t_raw_member_cap_control(self.source, self.class, self.id, method)
	else
		return t_cap_control(self.class, self.id, method)
	end
end

local function state_topic(self, field)
	if self.raw_kind == 'host' then
		return t_raw_host_cap_state(self.source, self.class, self.id, field)
	elseif self.raw_kind == 'member' then
		return t_raw_member_cap_state(self.source, self.class, self.id, field)
	else
		return t_cap_state(self.class, self.id, field)
	end
end

local function event_topic(self, name)
	if self.raw_kind == 'host' then
		return t_raw_host_cap_event(self.source, self.class, self.id, name)
	elseif self.raw_kind == 'member' then
		return t_raw_member_cap_event(self.source, self.class, self.id, name)
	else
		return t_cap_event(self.class, self.id, name)
	end
end

local function meta_topic(self)
	if self.raw_kind == 'host' then
		return t_raw_host_cap_meta(self.source, self.class, self.id)
	elseif self.raw_kind == 'member' then
		return t_raw_member_cap_meta(self.source, self.class, self.id)
	else
		return t_cap_meta(self.class, self.id)
	end
end

local function status_topic(self)
	if self.raw_kind == 'host' then
		return t_raw_host_cap_status(self.source, self.class, self.id)
	elseif self.raw_kind == 'member' then
		return t_raw_member_cap_status(self.source, self.class, self.id)
	else
		return t_cap_status(self.class, self.id)
	end
end

----------------------------------------------------------------------
-- Core op-only lane
-- All non-legacy constructors return these types.
----------------------------------------------------------------------

---@class CoreCapabilityReference
---@field conn Connection
---@field class CapabilityClass
---@field id CapabilityId
---@field raw_kind '"host"'|'"member"'|nil
---@field source string|nil
local CoreCapabilityReference = {}
CoreCapabilityReference.__index = CoreCapabilityReference

function CoreCapabilityReference:call_control_op(method, args, opts)
	return self.conn:call_op(control_topic(self, method), args, opts)
end

---@param field string
---@param opts table?
---@return Subscription
function CoreCapabilityReference:get_state_sub(field, opts)
	return self.conn:subscribe(state_topic(self, field), opts)
end

---@param name string
---@param opts table?
---@return Subscription
function CoreCapabilityReference:get_event_sub(name, opts)
	return self.conn:subscribe(event_topic(self, name), opts)
end

---@param opts table?
---@return Subscription
function CoreCapabilityReference:get_meta_sub(opts)
	return self.conn:subscribe(meta_topic(self), opts)
end

---@param opts table?
---@return Subscription
function CoreCapabilityReference:get_status_sub(opts)
	return self.conn:subscribe(status_topic(self), opts)
end

----------------------------------------------------------------------
-- Legacy compatibility lane
-- Sync convenience wrappers live here, and only here.
----------------------------------------------------------------------

---@class LegacyCapabilityReference : CoreCapabilityReference
local LegacyCapabilityReference = setmetatable({}, { __index = CoreCapabilityReference })
LegacyCapabilityReference.__index = LegacyCapabilityReference

---@class CapabilityReference : LegacyCapabilityReference

---@param method string
---@param args any
---@return Reply?
---@return string error
function LegacyCapabilityReference:call_control(method, args)
	return perform(self:call_control_op(method, args))
end

----------------------------------------------------------------------
-- Listener helpers
----------------------------------------------------------------------

local function new_core_cap_ref(conn, class, id, raw_kind, source)
	return setmetatable({
		conn     = conn,
		class    = class,
		id       = id,
		raw_kind = raw_kind,
		source   = source,
	}, CoreCapabilityReference)
end

local function new_legacy_cap_ref(conn, class, id)
	return setmetatable({
		conn  = conn,
		class = class,
		id    = id,
	}, LegacyCapabilityReference)
end

local function capability_ref_for_listener(self, class, id)
	if self.mode == 'legacy-public' then
		return new_legacy_cap_ref(self.conn, class, id)
	elseif self.mode == 'raw-host' then
		assert(self.source, 'raw-host listener missing source')
		return new_core_cap_ref(self.conn, class, id, 'host', self.source)
	elseif self.mode == 'raw-member' then
		assert(self.source, 'raw-member listener missing source')
		return new_core_cap_ref(self.conn, class, id, 'member', self.source)
	else
		return new_core_cap_ref(self.conn, class, id)
	end
end

local function listener_payload_is_ready(self, payload)
	if self.mode == 'legacy-public' then
		return payload == 'added'
	end

	if type(payload) ~= 'table' then
		return false
	end

	if self.mode == 'curated-public'
		or self.mode == 'raw-host'
		or self.mode == 'raw-member' then
		return payload.state == 'available'
			or payload.available == true
			or payload.state == 'running'
	end

	return false
end

local function listener_extract_class_and_id(self, msg)
	if self.mode == 'raw-host' or self.mode == 'raw-member' then
		return msg.topic[5], msg.topic[6]
	end
	return msg.topic[2], msg.topic[3]
end

local function noop_token()
	return {
		unlink = function ()
			return false
		end,
	}
end

----------------------------------------------------------------------
-- Core op-only listener
----------------------------------------------------------------------

---@class CoreCapListener
---@field conn Connection
---@field sub Subscription
---@field topic Topic
---@field mode '"legacy-public"'|'"curated-public"'|'"raw-host"'|'"raw-member"'
---@field source string|nil
local CoreCapListener = {}
CoreCapListener.__index = CoreCapListener

--- Wait for a capability to become ready and return a capability reference.
---
--- This uses wait.waitable2(...) so the wait remains properly op-first:
---   * probe_step is pure
---   * run_step drains already-buffered messages
---   * mailbox wakeup is provided by rx:on_message(...)
---
--- Note: this relies on Subscription._rx exposing the underlying mailbox
--- receiver. That coupling is intentionally boxed inside the SDK.
---@return Op
function CoreCapListener:wait_for_cap_op()
	local sub = assert(self.sub, 'cap listener has no subscription')
	local rx  = assert(sub._rx, 'CoreCapListener requires mailbox-backed subscription')
	assert(type(rx.recv_op) == 'function', 'CoreCapListener requires MailboxRx:recv_op()')
	assert(type(rx.on_message) == 'function', 'CoreCapListener requires MailboxRx:on_message()')

	local function probe_step()
		return false, 'capmsg'
	end

	local function run_step()
		while true do
			local recv_op = rx:recv_op()
			local ready, msg = recv_op.try_fn()

			if not ready then
				return false, 'capmsg'
			end

			if msg == nil then
				return true, nil, tostring(rx:why() or 'subscription closed')
			end

			if listener_payload_is_ready(self, msg.payload) then
				local class, id = listener_extract_class_and_id(self, msg)
				return true, capability_ref_for_listener(self, class, id), ''
			end
		end
	end

	local function register(task, waker, want)
		if want == 'run' then
			waker:wakeup(task)
			return noop_token()
		end
		return rx:on_message(task, waker)
	end

	return wait.waitable2(register, probe_step, run_step)
end

function CoreCapListener:close()
	self.sub:unsubscribe()
end

function CoreCapListener:terminate(_)
	self:close()
	return true, nil
end

function CoreCapListener:close_on_scope(scope)
	assert(scope ~= nil, 'CoreCapListener:close_on_scope requires scope')
	return scope:finally(function ()
		self:terminate('scope closed')
	end)
end

----------------------------------------------------------------------
-- Legacy compatibility listener
----------------------------------------------------------------------

---@class LegacyCapListener : CoreCapListener
local LegacyCapListener = setmetatable({}, { __index = CoreCapListener })
LegacyCapListener.__index = LegacyCapListener

---@param opts { timeout?: number }|nil
---@return LegacyCapabilityReference|CoreCapabilityReference|nil
---@return string error
function LegacyCapListener:wait_for_cap(opts)
	opts = opts or {}

	local ops = {
		cap = self:wait_for_cap_op(),
	}

	if opts.timeout then
		ops.timeout = sleep.sleep_op(opts.timeout)
	end

	local which, a, b = perform(op.named_choice(ops))
	if which == 'cap' then
		return a, b
	elseif which == 'timeout' then
		return nil, 'timeout'
	end

	return nil, 'unknown error'
end

----------------------------------------------------------------------
-- SDK
--
-- Constructor boundary:
--   * legacy constructors return sync-capable compatibility types
--   * all other constructors return strict op-only types
----------------------------------------------------------------------

---@class CapSDK
local CapSDK = {
	args = cap_args,
}
CapSDK.__index = CapSDK

----------------------------------------------------------------------
-- Legacy public helpers
-- For unchanged config/system callers.
----------------------------------------------------------------------

---@param conn Connection
---@param class CapabilityClass
---@param id CapabilityId
---@return LegacyCapListener
function CapSDK.new_cap_listener(conn, class, id)
	local topic = t_cap_listen(class, id)
	local sub = conn:subscribe(topic)
	return setmetatable({
		conn  = conn,
		sub   = sub,
		topic = topic,
		mode  = 'legacy-public',
	}, LegacyCapListener)
end

---@param conn Connection
---@param class CapabilityClass
---@param id CapabilityId
---@return LegacyCapabilityReference
function CapSDK.new_cap_ref(conn, class, id)
	return new_legacy_cap_ref(conn, class, id)
end

----------------------------------------------------------------------
-- New curated public helpers
-- Op-only.
----------------------------------------------------------------------

---@param conn Connection
---@param class CapabilityClass
---@param id CapabilityId
---@return CoreCapListener
function CapSDK.new_curated_cap_listener(conn, class, id)
	local topic = t_cap_status(class, id)
	local sub = conn:subscribe(topic)
	return setmetatable({
		conn  = conn,
		sub   = sub,
		topic = topic,
		mode  = 'curated-public',
	}, CoreCapListener)
end

---@param conn Connection
---@param class CapabilityClass
---@param id CapabilityId
---@return CoreCapabilityReference
function CapSDK.new_curated_cap_ref(conn, class, id)
	return new_core_cap_ref(conn, class, id)
end

----------------------------------------------------------------------
-- New raw host helpers
-- Op-only.
----------------------------------------------------------------------

---@param conn Connection
---@param source string
---@param class CapabilityClass
---@param id CapabilityId
---@return CoreCapListener
function CapSDK.new_raw_host_cap_listener(conn, source, class, id)
	source = assert_source(source, 1)
	local topic = t_raw_host_cap_status(source, class, id)
	local sub = conn:subscribe(topic)
	return setmetatable({
		conn   = conn,
		sub    = sub,
		topic  = topic,
		mode   = 'raw-host',
		source = source,
	}, CoreCapListener)
end

---@param conn Connection
---@param source string
---@param class CapabilityClass
---@param id CapabilityId
---@return CoreCapabilityReference
function CapSDK.new_raw_host_cap_ref(conn, source, class, id)
	source = assert_source(source, 1)
	return new_core_cap_ref(conn, class, id, 'host', source)
end

----------------------------------------------------------------------
-- New raw member helpers
-- Op-only.
----------------------------------------------------------------------

---@param conn Connection
---@param source string
---@param class CapabilityClass
---@param id CapabilityId
---@return CoreCapListener
function CapSDK.new_raw_member_cap_listener(conn, source, class, id)
	source = assert_source(source, 1)
	local topic = t_raw_member_cap_status(source, class, id)
	local sub = conn:subscribe(topic)
	return setmetatable({
		conn   = conn,
		sub    = sub,
		topic  = topic,
		mode   = 'raw-member',
		source = source,
	}, CoreCapListener)
end

---@param conn Connection
---@param source string
---@param class CapabilityClass
---@param id CapabilityId
---@return CoreCapabilityReference
function CapSDK.new_raw_member_cap_ref(conn, source, class, id)
	source = assert_source(source, 1)
	return new_core_cap_ref(conn, class, id, 'member', source)
end

return CapSDK
