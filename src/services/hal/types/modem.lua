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
---@field mode_port string
---@field at_port string
---@field net_port string
---@field device string
local ModemIdentity = {}
ModemIdentity.__index = ModemIdentity

---Create a new ModemIdentity.
---@param imei string
---@param address ModemAddress
---@param mode_port string
---@param at_port string
---@param net_port string
---@param device string
---@return ModemIdentity?
---@return string error
function new.ModemIdentity(imei, address, mode_port, at_port, net_port, device)
	if type(imei) ~= 'string' or imei == '' then
		return nil, "invalid imei"
	end

	if type(address) ~= 'string' or address == '' then
		return nil, "invalid address"
	end

	if type(mode_port) ~= 'string' or mode_port == '' then
		return nil, "invalid mode_port"
	end

	if type(at_port) ~= 'string' or at_port == '' then
		return nil, "invalid at_port"
	end

	if type(net_port) ~= 'string' or net_port == '' then
		return nil, "invalid net_port"
	end

	if type(device) ~= 'string' or device == '' then
		return nil, "invalid device"
	end

	local identity = setmetatable({
		imei = imei,
		address = address,
		mode_port = mode_port,
		at_port = at_port,
		net_port = net_port,
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

---@class ModemMonitorEvent
---@field is_added boolean
---@field address ModemAddress
local ModemMonitorEvent = {}
ModemMonitorEvent.__index = ModemMonitorEvent

---Create a new ModemMonitorEvent.
---@param is_added boolean
---@param address ModemAddress
---@return ModemMonitorEvent?
---@return string error
function new.ModemMonitorEvent(is_added, address)
	if type(is_added) ~= 'boolean' then
		return nil, "invalid is_added: expected boolean"
	end
	if type(address) ~= 'string' or address == '' then
		return nil, "invalid address"
	end
	return setmetatable({
		is_added = is_added,
		address = address,
	}, ModemMonitorEvent), ""
end

---@class ModemMonitor
---@field next_event_op fun(self: ModemMonitor): Op

---@class ModemBackend
---@field identity ModemIdentity
---@field cache Cache
---@field base string
---@field inhibit_cmd Command?
---@field state_monitor table?
---@field sim_present table?
---@field imei fun(self: ModemBackend, timeout: number?): string, string
---@field device fun(self: ModemBackend, timeout: number?): string, string
---@field primary_port fun(self: ModemBackend, timeout: number?): string, string
---@field at_ports fun(self: ModemBackend, timeout: number?): table, string
---@field qmi_ports fun(self: ModemBackend, timeout: number?): table, string
---@field gps_ports fun(self: ModemBackend, timeout: number?): table, string
---@field net_ports fun(self: ModemBackend, timeout: number?): table, string
---@field access_techs fun(self: ModemBackend, timeout: number?): table, string
---@field sim fun(self: ModemBackend, timeout: number?): string, string
---@field drivers fun(self: ModemBackend, timeout: number?): table, string
---@field plugin fun(self: ModemBackend, timeout: number?): string, string
---@field model fun(self: ModemBackend, timeout: number?): string, string
---@field revision fun(self: ModemBackend, timeout: number?): string, string
---@field operator fun(self: ModemBackend, timeout: number?): string, string
---@field rx_bytes fun(self: ModemBackend): integer, string
---@field tx_bytes fun(self: ModemBackend): integer, string
---@field signal fun(self: ModemBackend, timeout: number?): table, string
---@field mcc fun(self: ModemBackend, timeout: number?): string, string
---@field mnc fun(self: ModemBackend, timeout: number?): string, string
---@field gid1 fun(self: ModemBackend, timeout: number?): string, string
---@field active_band_class fun(self: ModemBackend, timeout: number?): string, string
---@field start_state_monitor fun(self: ModemBackend): boolean, string
---@field monitor_state_op fun(self: ModemBackend): Op
---@field start_sim_presence_monitor fun(self: ModemBackend): boolean, string
---@field wait_for_sim_present_op fun(self: ModemBackend): Op
---@field wait_for_sim_present fun(self: ModemBackend): boolean, string
---@field is_sim_present fun(self: ModemBackend): boolean, string
---@field trigger_sim_presence_check fun(self: ModemBackend, cooldown: number?): boolean, string
---@field enable fun(self: ModemBackend): boolean, string
---@field disable fun(self: ModemBackend): boolean, string
---@field reset fun(self: ModemBackend): boolean, string
---@field connect fun(self: ModemBackend, conn_string: string): boolean, string
---@field disconnect fun(self: ModemBackend): boolean, string
---@field inhibit fun(self: ModemBackend): boolean, string
---@field uninhibit fun(self: ModemBackend): boolean, string
---@field set_signal_update_interval fun(self: ModemBackend, interval: number): boolean, string

return {
	ModemDevice = ModemDevice,
	ModemIdentity = ModemIdentity,
	ModemStateEvent = ModemStateEvent,
	ModemMonitorEvent = ModemMonitorEvent,
	new = new,
}
