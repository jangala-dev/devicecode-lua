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

---@class ModemIdentityInfo
---@field imei string
---@field model string?
---@field revision string?
---@field firmware string?
---@field plugin string?
---@field drivers string[]
---@field mode string?
---@field model_variant string?
local ModemIdentityInfo = {}
ModemIdentityInfo.__index = ModemIdentityInfo

---@class ModemPortsInfo
---@field device string
---@field primary_port string?
---@field at_ports string[]
---@field qmi_ports string[]
---@field gps_ports string[]
---@field net_ports string[]
local ModemPortsInfo = {}
ModemPortsInfo.__index = ModemPortsInfo

---@class ModemSimInfo
---@field sim string?
---@field iccid string?
---@field imsi string?
---@field gid1 string?
local ModemSimInfo = {}
ModemSimInfo.__index = ModemSimInfo

---@class ModemNetworkInfo
---@field operator string?
---@field access_techs string[]
---@field mcc string?
---@field mnc string?
---@field active_band_class string?
local ModemNetworkInfo = {}
ModemNetworkInfo.__index = ModemNetworkInfo

---@class ModemSignalInfo
---@field values table<string, string|number>
local ModemSignalInfo = {}
ModemSignalInfo.__index = ModemSignalInfo

---@class ModemTrafficInfo
---@field rx_bytes integer
---@field tx_bytes integer
local ModemTrafficInfo = {}
ModemTrafficInfo.__index = ModemTrafficInfo

---@param values any
---@return boolean
local function is_string_array(values)
	if type(values) ~= 'table' then
		return false
	end
	for index, value in ipairs(values) do
		if type(index) ~= 'number' or type(value) ~= 'string' then
			return false
		end
	end
	return true
end

---@param value any
---@param field string
---@return boolean
---@return string
local function validate_optional_string(value, field)
	if value == nil then
		return true, ""
	end
	if type(value) ~= 'string' or value == '' then
		return false, "invalid " .. field
	end
	return true, ""
end

---@param value any
---@return boolean
local function is_signal_value_table(value)
	if type(value) ~= 'table' then
		return false
	end
	for key, entry in pairs(value) do
		if type(key) ~= 'string' then
			return false
		end
		local entry_type = type(entry)
		if entry_type ~= 'string' and entry_type ~= 'number' then
			return false
		end
	end
	return true
end

---Create a new ModemIdentityInfo.
---@param imei string
---@param drivers string[]
---@param model string?
---@param revision string?
---@param firmware string?
---@param plugin string?
---@param mode string?
---@param model_variant string?
---@return ModemIdentityInfo?
---@return string error
function new.ModemIdentityInfo(imei, drivers, model, revision, firmware, plugin, mode, model_variant)
	if type(imei) ~= 'string' or imei == '' then
		return nil, "invalid imei"
	end
	if not is_string_array(drivers) then
		return nil, "invalid drivers"
	end
	local ok, err = validate_optional_string(model, 'model')
	if not ok then
		return nil, err
	end
	ok, err = validate_optional_string(revision, 'revision')
	if not ok then
		return nil, err
	end
	ok, err = validate_optional_string(firmware, 'firmware')
	if not ok then
		return nil, err
	end
	ok, err = validate_optional_string(plugin, 'plugin')
	if not ok then
		return nil, err
	end
	ok, err = validate_optional_string(mode, 'mode')
	if not ok then
		return nil, err
	end
	ok, err = validate_optional_string(model_variant, 'model_variant')
	if not ok then
		return nil, err
	end

	return setmetatable({
		imei = imei,
		drivers = drivers,
		model = model,
		revision = revision,
		firmware = firmware,
		plugin = plugin,
		mode = mode,
		model_variant = model_variant,
	}, ModemIdentityInfo), ""
end

---Create a new ModemPortsInfo.
---@param device string
---@param primary_port string?
---@param at_ports string[]?
---@param qmi_ports string[]?
---@param gps_ports string[]?
---@param net_ports string[]?
---@return ModemPortsInfo?
---@return string error
function new.ModemPortsInfo(device, primary_port, at_ports, qmi_ports, gps_ports, net_ports)
	if type(device) ~= 'string' or device == '' then
		return nil, "invalid device"
	end
	local ok, err = validate_optional_string(primary_port, 'primary_port')
	if not ok then
		return nil, err
	end
	at_ports = at_ports or {}
	qmi_ports = qmi_ports or {}
	gps_ports = gps_ports or {}
	net_ports = net_ports or {}
	if not is_string_array(at_ports) then
		return nil, "invalid at_ports"
	end
	if not is_string_array(qmi_ports) then
		return nil, "invalid qmi_ports"
	end
	if not is_string_array(gps_ports) then
		return nil, "invalid gps_ports"
	end
	if not is_string_array(net_ports) then
		return nil, "invalid net_ports"
	end

	return setmetatable({
		device = device,
		primary_port = primary_port,
		at_ports = at_ports,
		qmi_ports = qmi_ports,
		gps_ports = gps_ports,
		net_ports = net_ports,
	}, ModemPortsInfo), ""
end

---Create a new ModemSimInfo.
---@param sim string?
---@param iccid string?
---@param imsi string?
---@param gid1 string?
---@return ModemSimInfo?
---@return string error
function new.ModemSimInfo(sim, iccid, imsi, gid1)
	local ok, err = validate_optional_string(sim, 'sim')
	if not ok then
		return nil, err
	end
	ok, err = validate_optional_string(iccid, 'iccid')
	if not ok then
		return nil, err
	end
	ok, err = validate_optional_string(imsi, 'imsi')
	if not ok then
		return nil, err
	end
	ok, err = validate_optional_string(gid1, 'gid1')
	if not ok then
		return nil, err
	end

	return setmetatable({
		sim = sim,
		iccid = iccid,
		imsi = imsi,
		gid1 = gid1,
	}, ModemSimInfo), ""
end

---Create a new ModemNetworkInfo.
---@param operator string?
---@param access_techs string[]?
---@param mcc string?
---@param mnc string?
---@param active_band_class string?
---@return ModemNetworkInfo?
---@return string error
function new.ModemNetworkInfo(operator, access_techs, mcc, mnc, active_band_class)
	local ok, err = validate_optional_string(operator, 'operator')
	if not ok then
		return nil, err
	end
	access_techs = access_techs or {}
	if not is_string_array(access_techs) then
		return nil, "invalid access_techs"
	end
	ok, err = validate_optional_string(mcc, 'mcc')
	if not ok then
		return nil, err
	end
	ok, err = validate_optional_string(mnc, 'mnc')
	if not ok then
		return nil, err
	end
	ok, err = validate_optional_string(active_band_class, 'active_band_class')
	if not ok then
		return nil, err
	end

	return setmetatable({
		operator = operator,
		access_techs = access_techs,
		mcc = mcc,
		mnc = mnc,
		active_band_class = active_band_class,
	}, ModemNetworkInfo), ""
end

---Create a new ModemSignalInfo.
---@param values table<string, string|number>
---@return ModemSignalInfo?
---@return string error
function new.ModemSignalInfo(values)
	if not is_signal_value_table(values) then
		return nil, "invalid signal values"
	end
	return setmetatable({ values = values }, ModemSignalInfo), ""
end

---Create a new ModemTrafficInfo.
---@param rx_bytes integer
---@param tx_bytes integer
---@return ModemTrafficInfo?
---@return string error
function new.ModemTrafficInfo(rx_bytes, tx_bytes)
	if type(rx_bytes) ~= 'number' or rx_bytes < 0 then
		return nil, "invalid rx_bytes"
	end
	if type(tx_bytes) ~= 'number' or tx_bytes < 0 then
		return nil, "invalid tx_bytes"
	end
	return setmetatable({
		rx_bytes = rx_bytes,
		tx_bytes = tx_bytes,
	}, ModemTrafficInfo), ""
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
---@field base string
---@field last_state_event ModemStateEvent?
---@field inhibit_cmd Command?
---@field state_monitor table?
---@field sim_present table?
---@field read_identity fun(self: ModemBackend): ModemIdentityInfo?, string
---@field read_ports fun(self: ModemBackend): ModemPortsInfo?, string
---@field read_sim_info fun(self: ModemBackend): ModemSimInfo?, string
---@field read_network_info fun(self: ModemBackend): ModemNetworkInfo?, string
---@field read_signal fun(self: ModemBackend): ModemSignalInfo?, string
---@field read_traffic fun(self: ModemBackend): ModemTrafficInfo?, string
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
	ModemIdentityInfo = ModemIdentityInfo,
	ModemPortsInfo = ModemPortsInfo,
	ModemSimInfo = ModemSimInfo,
	ModemNetworkInfo = ModemNetworkInfo,
	ModemSignalInfo = ModemSignalInfo,
	ModemTrafficInfo = ModemTrafficInfo,
	ModemStateEvent = ModemStateEvent,
	ModemMonitorEvent = ModemMonitorEvent,
	new = new,
}
