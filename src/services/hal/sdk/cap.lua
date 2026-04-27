local cap_args = require 'services.hal.types.capability_args'

local fibers = require 'fibers'
local scope = require 'fibers.scope'
local sleep = require 'fibers.sleep'
local op = require 'fibers.op'

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
-- Capability reference
----------------------------------------------------------------------

---@class CapabilityReference
---@field conn Connection
---@field class CapabilityClass
---@field id CapabilityId
local CapabilityReference = {}
CapabilityReference.__index = CapabilityReference

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

function CapabilityReference:call_control_op(method, args, opts)
	return self.conn:call_op(control_topic(self, method), args, opts)
end

---@param method string
---@param args any
---@return Reply?
---@return string error
function CapabilityReference:call_control(method, args)
	return perform(self:call_control_op(method, args))
end

---@param field string
---@param opts table?
---@return Subscription
function CapabilityReference:get_state_sub(field, opts)
	return self.conn:subscribe(state_topic(self, field), opts)
end

---@param name string
---@param opts table?
---@return Subscription
function CapabilityReference:get_event_sub(name, opts)
	return self.conn:subscribe(event_topic(self, name), opts)
end

---@param opts table?
---@return Subscription
function CapabilityReference:get_meta_sub(opts)
	return self.conn:subscribe(meta_topic(self), opts)
end

---@param opts table?
---@return Subscription
function CapabilityReference:get_status_sub(opts)
	return self.conn:subscribe(status_topic(self), opts)
end

----------------------------------------------------------------------
-- Listener
----------------------------------------------------------------------

---@class CapListener
---@field conn Connection
---@field sub Subscription
---@field topic Topic
---@field mode '"legacy-public"'|'"curated-public"'|'"raw-host"'|'"raw-member"'
local CapListener = {}
CapListener.__index = CapListener

local function capability_ref_for_listener(self, class, id)
	if self.mode == 'raw-host' then
		return setmetatable({
			conn = self.conn,
			raw_kind = 'host',
			source = self.source,
			class = class,
			id = id,
		}, CapabilityReference)
	elseif self.mode == 'raw-member' then
		return setmetatable({
			conn = self.conn,
			raw_kind = 'member',
			source = self.source,
			class = class,
			id = id,
		}, CapabilityReference)
	else
		return setmetatable({
			conn = self.conn,
			class = class,
			id = id,
		}, CapabilityReference)
	end
end

local function listener_payload_is_ready(self, payload)
	if self.mode == 'legacy-public' then
		return payload == 'added'
	end

	if type(payload) == 'table' then
		if payload.state == 'available' or payload.available == true then
			return true
		end
		if payload.state == 'running' then
			return true
		end
	end

	-- Helpful transitional fallback if somebody mirrors old semantics.
	if payload == 'added' then
		return true
	end

	return false
end

--- Wait for a capability to be available matching the listener's topic, and
--- return a reference to it.
function CapListener:wait_for_cap_op()
	return scope.run_op(function()
		while true do
			local msg, err = self.sub:recv()
			if err then return nil, err end
			if not msg then return nil, 'subscription closed' end

			local payload = msg.payload
			if listener_payload_is_ready(self, payload) then
				local class, id
				if self.mode == 'raw-host' or self.mode == 'raw-member' then
					class, id = msg.topic[5], msg.topic[6]
				else
					class, id = msg.topic[2], msg.topic[3]
				end
				return capability_ref_for_listener(self, class, id), ''
			end
		end
	end):wrap(function(st, report, cap, err)
		if st == 'ok' then
			return cap, err or ''
		else
			return nil, tostring(report)
		end
	end)
end

---@param opts { timeout?: number }
---@return CapabilityReference?
---@return string error
function CapListener:wait_for_cap(opts)
	opts = opts or {}
	local ops = { cap = self:wait_for_cap_op() }
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

function CapListener:close()
	self.sub:unsubscribe()
end

----------------------------------------------------------------------
-- SDK
----------------------------------------------------------------------

---@class CapSDK
local CapSDK = {
	args = cap_args,
}
CapSDK.__index = CapSDK

----------------------------------------------------------------------
-- Legacy public helpers
-- Keep these intact so existing services continue to work.
----------------------------------------------------------------------

---@param conn Connection
---@param class CapabilityClass
---@param id CapabilityId
function CapSDK.new_cap_listener(conn, class, id)
	local topic = t_cap_listen(class, id)
	local sub = conn:subscribe(topic)
	return setmetatable({
		conn = conn,
		sub = sub,
		topic = topic,
		mode = 'legacy-public',
	}, CapListener)
end

---@param conn Connection
---@param class CapabilityClass
---@param id CapabilityId
---@return CapabilityReference
function CapSDK.new_cap_ref(conn, class, id)
	return setmetatable({ conn = conn, class = class, id = id }, CapabilityReference)
end

----------------------------------------------------------------------
-- New curated public helpers
----------------------------------------------------------------------

---@param conn Connection
---@param class CapabilityClass
---@param id CapabilityId
function CapSDK.new_curated_cap_listener(conn, class, id)
	local topic = t_cap_status(class, id)
	local sub = conn:subscribe(topic)
	return setmetatable({
		conn = conn,
		sub = sub,
		topic = topic,
		mode = 'curated-public',
	}, CapListener)
end

---@param conn Connection
---@param class CapabilityClass
---@param id CapabilityId
---@return CapabilityReference
function CapSDK.new_curated_cap_ref(conn, class, id)
	return setmetatable({ conn = conn, class = class, id = id }, CapabilityReference)
end

----------------------------------------------------------------------
-- Raw host helpers
----------------------------------------------------------------------

---@param conn Connection
---@param source string
---@param class CapabilityClass
---@param id CapabilityId
function CapSDK.new_raw_host_cap_listener(conn, source, class, id)
	local topic = t_raw_host_cap_status(source, class, id)
	local sub = conn:subscribe(topic)
	return setmetatable({
		conn = conn,
		sub = sub,
		topic = topic,
		mode = 'raw-host',
		source = source,
	}, CapListener)
end

---@param conn Connection
---@param source string
---@param class CapabilityClass
---@param id CapabilityId
---@return CapabilityReference
function CapSDK.new_raw_host_cap_ref(conn, source, class, id)
	return setmetatable({
		conn = conn,
		raw_kind = 'host',
		source = source,
		class = class,
		id = id,
	}, CapabilityReference)
end

----------------------------------------------------------------------
-- Raw member helpers
----------------------------------------------------------------------

---@param conn Connection
---@param source string
---@param class CapabilityClass
---@param id CapabilityId
function CapSDK.new_raw_member_cap_listener(conn, source, class, id)
	local topic = t_raw_member_cap_status(source, class, id)
	local sub = conn:subscribe(topic)
	return setmetatable({
		conn = conn,
		sub = sub,
		topic = topic,
		mode = 'raw-member',
		source = source,
	}, CapListener)
end

---@param conn Connection
---@param source string
---@param class CapabilityClass
---@param id CapabilityId
---@return CapabilityReference
function CapSDK.new_raw_member_cap_ref(conn, source, class, id)
	return setmetatable({
		conn = conn,
		raw_kind = 'member',
		source = source,
		class = class,
		id = id,
	}, CapabilityReference)
end

return CapSDK
