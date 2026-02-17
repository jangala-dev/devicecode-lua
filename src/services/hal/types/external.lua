local new = {}

---@class ModemGetOpts
---@field field string
---@field timescale? number
local ModemGetOpts = {}
ModemGetOpts.__index = ModemGetOpts

---Create a new ModemGetOpts.
---@param field string
---@param timescale? number
---@return ModemGetOpts?
---@return string error
function new.ModemGetOpts(field, timescale)
    if type(field) ~= 'string' or field == '' then
        return nil, "invalid field"
    end

    if timescale ~= nil and (type(timescale) ~= 'number' or timescale <= 0) then
        return nil, "invalid timescale"
    end

    return setmetatable({
        field = field,
        timescale = timescale,
    }, ModemGetOpts), ""
end

---@class ModemConnectOpts
---@field connection_string string
local ModemConnectOpts = {}
ModemConnectOpts.__index = ModemConnectOpts

---Create a new ModemConnectOpts.
---@param connection_string string
---@return ModemConnectOpts?
---@return string error
function new.ModemConnectOpts(connection_string)
    if type(connection_string) ~= 'string' or connection_string == '' then
        return nil, "invalid connection string"
    end
    return setmetatable({
        connection_string = connection_string,
    }, ModemConnectOpts), ""
end

---@class ModemSignalUpdateOpts
---@field frequency number
local ModemSignalUpdateOpts = {}
ModemSignalUpdateOpts.__index = ModemSignalUpdateOpts

---Create a new ModemSignalUpdateOpts.
---@param frequency number
---@return ModemSignalUpdateOpts?
---@return string error
function new.ModemSignalUpdateOpts(frequency)
    if type(frequency) ~= 'number' or frequency <= 0 then
        return nil, "invalid frequency"
    end
    return setmetatable({
        frequency = frequency,
    }, ModemSignalUpdateOpts), ""
end

return {
    ModemGetOpts = ModemGetOpts,
    ModemConnectOpts = ModemConnectOpts,
    new = new,
}
