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

    if timescale ~= nil and (type(timescale) ~= 'number' or timescale < 0) then
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

---@class FilesystemReadOpts
---@field filename string
local FilesystemReadOpts = {}
FilesystemReadOpts.__index = FilesystemReadOpts

--- Validate that a filename contains no path separators or .. segments
---@param filename string
---@return boolean valid
---@return string? error
local function validate_filename(filename)
    if type(filename) ~= 'string' or filename == '' then
        return false, "filename must be a non-empty string"
    end

    if filename:find('/') or filename:find('\\') then
        return false, "filename cannot contain path separators"
    end

    if filename == '..' or filename:find('^%.%.') or filename:find('%.%.') then
        return false, "filename cannot contain .. segments"
    end

    return true, nil
end

---Create a new FilesystemReadOpts
---@param filename string
---@return FilesystemReadOpts?
---@return string error
function new.FilesystemReadOpts(filename)
    local valid, err = validate_filename(filename)
    if not valid then
        return nil, err
    end
    return setmetatable({
        filename = filename,
    }, FilesystemReadOpts), ""
end

---@class FilesystemWriteOpts
---@field filename string
---@field data string
local FilesystemWriteOpts = {}
FilesystemWriteOpts.__index = FilesystemWriteOpts

---Create a new FilesystemWriteOpts
---@param filename string
---@param data string
---@return FilesystemWriteOpts?
---@return string error
function new.FilesystemWriteOpts(filename, data)
    local valid, err = validate_filename(filename)
    if not valid then
        return nil, err
    end
    if type(data) ~= 'string' then
        return nil, "invalid data"
    end
    return setmetatable({
        filename = filename,
        data = data,
    }, FilesystemWriteOpts), ""
end

return {
    ModemGetOpts = ModemGetOpts,
    ModemConnectOpts = ModemConnectOpts,
    FilesystemReadOpts = FilesystemReadOpts,
    FilesystemWriteOpts = FilesystemWriteOpts,
    new = new,
}
