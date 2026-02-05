---@alias ModemAddress string

---@class ModemDevice
---@field driver Modem
---@field device string
local ModemDevice = {}
ModemDevice.__index = ModemDevice

---@class ModemTypeConstructors
local new = {}

---Create a new ModemDevice.
---@param driver Modem
---@param device string
---@return ModemDevice?
---@return string error
function new.ModemDevice(driver, device)
	if driver == nil then
		return nil, "invalid driver"
	end

	if type(device) ~= 'string' or device == '' then
		return nil, "invalid device"
	end

	return setmetatable({
		driver = driver,
		device = device,
	}, ModemDevice), ""
end

---@class ModemIdentity
---@field imei string
---@field address ModemAddress
---@field primary_port string
---@field at_port string
---@field device string
local ModemIdentity = {}
ModemIdentity.__index = ModemIdentity

---Create a new ModemIdentity.
---@param imei string
---@param address ModemAddress
---@param primary_port string
---@param at_port string
---@param device string
---@return ModemIdentity?
---@return string error
function new.ModemIdentity(imei, address, primary_port, at_port, device)
	if type(imei) ~= 'string' or imei == '' then
		return nil, "invalid imei"
	end

	if type(address) ~= 'string' or address == '' then
		return nil, "invalid address"
	end

	if type(primary_port) ~= 'string' or primary_port == '' then
		return nil, "invalid primary_port"
	end

	if type(at_port) ~= 'string' or at_port == '' then
		return nil, "invalid at_port"
	end

	if type(device) ~= 'string' or device == '' then
		return nil, "invalid device"
	end

	local identity = setmetatable({
		imei = imei,
		address = address,
		primary_port = primary_port,
		at_port = at_port,
		device = device,
	}, ModemIdentity)
	return identity, ""
end

---@alias ModemStateEventType "initial"|"changed"|"removed"
---@alias ModemState string

---@class ModemStateEvent
---@field ev_type ModemStateEventType
---@field from ModemState
---@field to ModemState
---@field reason string?
local ModemStateEvent = {}
ModemStateEvent.__index = ModemStateEvent

--- Creates a new ModemStateEvent.
---@param ev_type ModemStateEventType
---@param from ModemState
---@param to ModemState
---@param reason string?
---@return ModemStateEvent?
---@return string error
function new.ModemStateEvent(ev_type, from, to, reason)
	if ev_type ~= "initial" and ev_type ~= "changed" and ev_type ~= "removed" then
		return nil, "invalid event type"
	end

	if type(from) ~= 'string' or from == '' then
		return nil, "invalid from state"
	end

	if type(to) ~= 'string' or to == '' then
		return nil, "invalid to state"
	end

	reason = reason or "unknown"
	if (type(reason) ~= 'string' or reason == '') then
		return nil, "invalid reason"
	end

	local event = setmetatable({
		ev_type = ev_type,
		from = from,
		to = to,
		reason = reason,
	}, { __index = ModemStateEvent })
	return event, ""
end

function new.ModemStateInitialEvent(state, reason)
	return new.ModemStateEvent("initial", state, state, reason)
end

function new.ModemStateChangeEvent(from, to, reason)
	return new.ModemStateEvent("changed", from, to, reason)
end

function new.ModemStateRemovedEvent(reason)
	return new.ModemStateEvent("removed", "removed", "removed", reason)
end

return {
	ModemDevice = ModemDevice,
	ModemIdentity = ModemIdentity,
	ModemStateEvent = ModemStateEvent,
	new = new,
}
