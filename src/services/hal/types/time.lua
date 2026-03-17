---@alias NTPAction string

---@class NTPEvent
---@field stratum number NTP stratum level (0-15: synced, 16: unsynced)
---@field action NTPAction Event action (e.g., "step", "clock", "leap")
---@field offset number Clock offset in seconds
---@field freq_drift_ppm number Frequency drift in parts per million
---@field [string] any Additional fields from backend
local NTPEvent = {}
NTPEvent.__index = NTPEvent

---@class TimeTypeConstructors
local new = {}

---Create a new NTPEvent.
---
---@param stratum number NTP stratum (0-15 synced, 16 unsynced)
---@param action string Event action
---@param offset number Clock offset in seconds
---@param freq_drift_ppm number Frequency drift in ppm
---@return NTPEvent?
---@return string error
function new.NTPEvent(stratum, action, offset, freq_drift_ppm)
	if type(stratum) ~= 'number' then
		return nil, "invalid stratum"
	end

	if type(action) ~= 'string' or action == '' then
		return nil, "invalid action"
	end

	if type(offset) ~= 'number' then
		return nil, "invalid offset"
	end

	if type(freq_drift_ppm) ~= 'number' then
		return nil, "invalid freq_drift_ppm"
	end

	local event = setmetatable({
		stratum = stratum,
		action = action,
		offset = offset,
		freq_drift_ppm = freq_drift_ppm,
	}, NTPEvent)
	return event, ""
end

---@class TimeBackend
---@field start_ntp_monitor fun(self: TimeBackend): boolean, string
---@field ntp_event_op fun(self: TimeBackend): Op
---@field stop fun(self: TimeBackend): boolean, string

return {
	NTPEvent = NTPEvent,
	new = new,
}
