---@param list string[]
---@return table<string, boolean>
local function list_to_map(list)
    local map = {}
    for _, v in ipairs(list) do
        map[v] = true
    end
    return map
end

local channel = require "fibers.channel"
local ChannelMT = getmetatable(channel.new())

local function valid_class(class)
    return type(class) == 'string' and class ~= ''
end

local function valid_id(id)
    return (type(id) == 'string' and id ~= '') or (type(id) == 'number' and id >= 0)
end

local function valid_offerings(offerings)
    if type(offerings) ~= 'table' then
        return false
    end
    for _, v in ipairs(offerings) do
        if type(v) ~= 'string' or v == '' then
            return false
        end
    end
    return true
end

---@alias CapabilityClass string
---@alias CapabilityId string|integer
---@alias CapabilityOffering string
---@alias CapabilityOfferingMap table<string, boolean>

---@class CapabilityConstructors
local new = {}


---@class Capability
---@field class CapabilityClass
---@field id CapabilityId
---@field offerings CapabilityOfferingMap
---@field control_ch Channel
local Capability = {}
Capability.__index = Capability

---@param class CapabilityClass
---@param id CapabilityId
---@param control_ch Channel
---@param offerings CapabilityOffering[]
---@return Capability?
---@return string error
function new.Capability(class, id, control_ch, offerings)
    if not valid_class(class) then
        return nil, "invalid capability class"
    end

    if not valid_id(id) then
        return nil, "invalid capability id"
    end

    if getmetatable(control_ch) ~= ChannelMT then
        return nil, "invalid capability control_ch"
    end

    if not valid_offerings(offerings) then
        return nil, "invalid capability offerings"
    end

    local offerings_map = list_to_map(offerings)

    local capability = setmetatable({
        class = class,
        id = id,
        offerings = offerings_map,
        control_ch = control_ch,
    }, Capability)

    return capability, ""
end

---@param id CapabilityId
---@param control_ch Channel
---@return Capability?
---@return string error
function new.ModemCapability(id, control_ch)
    local offerings = {
        'get',
        'enable',
        'disable',
        'restart',
        'connect',
        'disconnect',
        'sim_detect',
        'fix_failure',
        'set_signal_update_freq',
    }
    return new.Capability('modem', id, control_ch, offerings)
end

---@param id CapabilityId
---@param control_ch Channel
---@return Capability?
---@return string error
function new.GeoCapability(id, control_ch)
    local offerings = {}
    return new.Capability('geo', id, control_ch, offerings)
end

---@param id CapabilityId
---@param control_ch Channel
---@return Capability?
---@return string error
function new.TimeCapability(id, control_ch)
    local offerings = {}
    return new.Capability('time', id, control_ch, offerings)
end

---@param id CapabilityId
---@param control_ch Channel
---@return Capability?
---@return string error
function new.NetworkCapability(id, control_ch)
    local offerings = {}
    return new.Capability('network', id, control_ch, offerings)
end

---@param id CapabilityId
---@param control_ch Channel
---@return Capability?
---@return string error
function new.WirelessCapability(id, control_ch)
    local offerings = {
        'set_channels',
        'set_country',
        'set_txpower',
        'set_type',
        'set_enabled',
        'add_interface',
        'delete_interface',
        'clear_radio_config',
        'apply'
    }
    return new.Capability('wireless', id, control_ch, offerings)
end

---@param id CapabilityId
---@param control_ch Channel
---@return Capability?
---@return string error
function new.BandCapability(id, control_ch)
    local offerings = {
        'set_log_level',
        'set_kicking',
        'set_station_counting',
        'set_rrm_mode',
        'set_neighbour_reports',
        'set_legacy_options',
        'set_band_priority',
        'set_band_kicking',
        'set_support_bonus',
        'set_update_freq',
        'set_client_inactive_kickoff',
        'set_cleanup',
        'set_networking',
        'apply'
    }
    return new.Capability('band', id, control_ch, offerings)
end

---@param id CapabilityId
---@param control_ch Channel
---@return Capability?
---@return string error
function new.SerialCapability(id, control_ch)
    local offerings = {
        'open', 'close', 'write'
    }
    return new.Capability('serial', id, control_ch, offerings)
end

---@param id CapabilityId
---@param control_ch Channel
---@return Capability?
---@return string error
function new.FilesystemCapability(id, control_ch)
    local offerings = {
        'read',
        'write'
    }
    return new.Capability('fs', id, control_ch, offerings)
end

---@class ControlError
---@field reason string
---@field code integer
local ControlError = {}
ControlError.__index = ControlError

---@param reason string
---@param code integer?
---@return ControlError
function new.ControlError(reason, code)
    if type(reason) ~= 'string' then
        reason = tostring(reason)
    end

    if type(code) ~= 'number' or code < 0 then
        code = 1
    end

    local control_error = setmetatable({
        reason = reason,
        code = code,
    }, ControlError)
    return control_error
end

return {
    Capability = Capability,
    ControlError = ControlError,
    new = new,
}
