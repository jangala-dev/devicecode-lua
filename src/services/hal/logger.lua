-- services/hal/logger.lua
--
-- Lightweight structured logger for HAL managers and drivers.
-- Wraps an emit function (level, payload) and merges a set of
-- static metadata fields into every emitted payload.

---@class Logger
---@field _emit fun(level: string, payload: any)
---@field _fields table<string, any>
local Logger = {}
Logger.__index = Logger

local function merge(a, b)
    local out = {}
    if type(a) == 'table' then
        for k, v in pairs(a) do out[k] = v end
    end
    if type(b) == 'table' then
        for k, v in pairs(b) do out[k] = v end
    end
    return out
end

---Create a new Logger.
---@param emit_fn fun(level: string, payload: any)
---@param fields table<string, any>
---@return Logger
function Logger.new(emit_fn, fields)
    return setmetatable({
        _emit   = emit_fn,
        _fields = fields or {},
    }, Logger)
end

---Create a child logger that inherits fields and adds extra ones.
---@param extra_fields table<string, any>
---@return Logger
function Logger:child(extra_fields)
    return Logger.new(self._emit, merge(self._fields, extra_fields))
end

---@param payload any
function Logger:debug(payload)
    if type(payload) == 'table' then payload = merge(self._fields, payload) end
    self._emit('debug', payload)
end

---@param payload any
function Logger:info(payload)
    if type(payload) == 'table' then payload = merge(self._fields, payload) end
    self._emit('info', payload)
end

---@param payload any
function Logger:warn(payload)
    if type(payload) == 'table' then payload = merge(self._fields, payload) end
    self._emit('warn', payload)
end

---@param payload any
function Logger:error(payload)
    if type(payload) == 'table' then payload = merge(self._fields, payload) end
    self._emit('error', payload)
end

---@param payload any
function Logger:trace(payload)
    if type(payload) == 'table' then payload = merge(self._fields, payload) end
    self._emit('trace', payload)
end

return Logger
