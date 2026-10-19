---@alias DeviceClass string
---@alias DeviceId string|integer

---@alias Meta table<string, any>

---@alias CapList Capability[]

local cap_types = require "services.hal.types.capabilities"
local channel = require "fibers.channel"
local ChannelMT = getmetatable(channel.new())

---@class TypeConstructors
local new = {}


---@class ControlRequest
---@field verb string
---@field opts table<string, any>
---@field reply_ch Channel
---@field cancel_op Op?
local ControlRequest = {}
ControlRequest.__index = ControlRequest

---Create a new ControlRequest.
---@param verb string
---@param opts table<string, any>
---@param reply_ch Channel
---@param cancel_op Op?
---@return ControlRequest?
---@return string error
function new.ControlRequest(verb, opts, reply_ch, cancel_op)
	if type(verb) ~= 'string' or verb == '' then
		return nil, "invalid verb"
	end

	if type(opts) ~= 'table' then
		return nil, "opts must be a table"
	end

	if getmetatable(reply_ch) ~= ChannelMT then
		return nil, "invalid reply_ch"
	end

	return setmetatable({
		verb = verb,
		opts = opts,
		reply_ch = reply_ch,
		cancel_op = cancel_op,
	}, ControlRequest), ""
end

---@class Reply
---@field ok boolean
---@field reason any
---@field code integer?
local Reply = {}
Reply.__index = Reply

---Create a new Reply.
---@param ok boolean
---@param reason string?
---@param code integer?
---@return Reply?
---@return string error
function new.Reply(ok, reason, code)
	if type(ok) ~= 'boolean' then
		return nil, "invalid ok"
	end

	return setmetatable({
		ok = ok,
		reason = reason,
		code = code,
	}, Reply), ""
end

---@alias EmitMode 'event'|'state'|'meta'|'log'

---@class Emit
---@field class CapabilityClass
---@field id CapabilityId
---@field mode EmitMode
---@field key string
---@field data any
local Emit = {}
Emit.__index = Emit

---Create a new Emit.
---@param class CapabilityClass
---@param id CapabilityId
---@param mode EmitMode
---@param key string
---@param data any
---@return Emit?
---@return string error
function new.Emit(class, id, mode, key, data)
	if type(class) ~= 'string' or class == '' then
		return nil, "invalid class"
	end

	if type(id) ~= 'string' and type(id) ~= 'number' then
		return nil, "invalid id"
	end

	if mode ~= 'event' and mode ~= 'state' and mode ~= 'meta' and mode ~= 'log' then
		return nil, "invalid mode"
	end

	if type(key) ~= 'string' or key == '' then
		return nil, "invalid key"
	end

	if type(data) == 'nil' then
		return nil, "data cannot be nil"
	end

	return setmetatable({
		class = class,
		id = id,
		mode = mode,
		key = key,
		data = data,
	}, Emit), ""
end

---@alias EventType 'added'|'removed'

---@class DeviceEvent
---@field event_type EventType
---@field class DeviceClass
---@field id DeviceId
---@field meta Meta
---@field capabilities CapList
---@field ready_cond Cond? Optional one-shot condition; signalled by HAL after the device is fully registered.
local DeviceEvent = {}
DeviceEvent.__index = DeviceEvent

---Create a new DeviceEvent.
---@param event_type EventType
---@param class DeviceClass
---@param id DeviceId
---@param meta Meta?
---@param capabilities CapList?
---@param ready_cond Cond? Optional one-shot condition; signalled by HAL after the device is fully registered.
---@return DeviceEvent?
---@return string error
function new.DeviceEvent(event_type, class, id, meta, capabilities, ready_cond)
	meta = meta or {}
	capabilities = capabilities or {}

	if event_type ~= 'added' and event_type ~= 'removed' then
		return nil, "invalid event_type"
	end

	if type(class) ~= 'string' or class == '' then
		return nil, "invalid class"
	end

	if type(id) ~= 'string' and type(id) ~= 'number' then
		return nil, "invalid id"
	end

	if type(meta) ~= 'table' then
		return nil, "invalid meta"
	end

	if type(capabilities) ~= 'table' then
		return nil, "invalid capabilities"
	end
	for _, cap in ipairs(capabilities) do
		if getmetatable(cap) ~= cap_types.Capability then
			return nil, "invalid capability in capabilities"
		end
	end

	if ready_cond ~= nil and type(ready_cond.signal) ~= 'function' then
		return nil, "invalid ready_cond"
	end

	local ev = setmetatable({
		event_type  = event_type,
		class       = class,
		id          = id,
		meta        = meta,
		capabilities = capabilities,
		ready_cond  = ready_cond,
	}, DeviceEvent)

	return ev, ""
end

---@class Device
---@field class DeviceClass
---@field id DeviceId
---@field meta Meta
---@field capabilities Capability[]
local Device = {}
Device.__index = Device

---Create a new Device.
---@param class DeviceClass
---@param id DeviceId
---@param meta Meta
---@param capabilities CapList
---@return Device?
---@return string error
function new.Device(class, id, meta, capabilities)
	meta = meta or {}
	capabilities = capabilities or {}

	if type(class) ~= 'string' or class == '' then
		return nil, "invalid class"
	end

	if type(id) ~= 'string' and type(id) ~= 'number' then
		return nil, "invalid id"
	end

	if type(meta) ~= 'table' then
		return nil, "invalid meta"
	end

	if type(capabilities) ~= 'table' then
		return nil, "invalid capabilities"
	end
	for _, cap in ipairs(capabilities) do
		if getmetatable(cap) ~= cap_types.Capability then
			return nil, "invalid capability in capabilities"
		end
	end

	local dev = setmetatable({
		class = class,
		id = id,
		meta = meta,
		capabilities = capabilities,
	}, Device)
	return dev, ""
end

-- Todo types:
---@class Manager
---@field scope Scope
---@field start fun(logger: table|nil, dev_ev_ch: Channel, cap_emit_ch: Channel): string error
---@field stop fun(): string error
---@field apply_config fun(config: table): boolean ok, string error

----------------------------------------------------------------------
-- UART open reply
----------------------------------------------------------------------

---@class UARTOpenReply
---@field lease_id string
---@field session any
---@field path string
---@field baud integer|nil
---@field mode string|nil
local UARTOpenReply = {}
UARTOpenReply.__index = UARTOpenReply

---@param lease_id string
---@param session any
---@param path string
---@param baud integer|nil
---@param mode string|nil
---@return UARTOpenReply?|nil
---@return string
function new.UARTOpenReply(lease_id, session, path, baud, mode)
	if type(lease_id) ~= 'string' or lease_id == '' then
		return nil, 'invalid lease_id'
	end
	if session == nil then
		return nil, 'missing session'
	end
	if type(path) ~= 'string' or path == '' then
		return nil, 'invalid path'
	end
	if baud ~= nil and (type(baud) ~= 'number' or baud <= 0 or baud % 1 ~= 0) then
		return nil, 'invalid baud'
	end
	if mode ~= nil and type(mode) ~= 'string' then
		return nil, 'invalid mode'
	end

	return setmetatable({
		lease_id = lease_id,
		session  = session,
		path     = path,
		baud     = baud,
		mode     = mode,
	}, UARTOpenReply), ''
end

return {
	ControlRequest = ControlRequest,
	Reply = Reply,
	Emit = Emit,
	DeviceEvent = DeviceEvent,
	Device = Device,
	UARTOpenReply = UARTOpenReply,
	new = new,
}
