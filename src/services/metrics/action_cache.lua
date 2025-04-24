---@param t table
---@return boolean
local function is_array(t)
    if type(t) ~= 'table' then return false end
    local i = 0
    for _ in pairs(t) do
        i = i + 1
        if t[i] == nil then return false end
    end
    return true
end

---@class ActionCache
---@field separator string
---@field store table
local ActionCache = {}
ActionCache.__index = ActionCache

---Creates a new ActionCache instance
---@param separator string? Separator character for compound keys
---@return ActionCache
function ActionCache.new(separator)
    local self = setmetatable({}, ActionCache)
    self.separator = separator or string.char(31)
    self.store = {}
    return self
end

---Sets a value in the cache with a new process
---@param key string|table Key to store value under
---@param value any Value to store
---@param process Process Process to handle the value
---@return any value
---@return boolean short_circuit
---@return string? Error
function ActionCache:set(key, value, process)
    if process == nil then return nil, true, 'process must be a valid process, not nil' end
    key = type(key) == 'string' and key or table.concat(key, self.separator)
    if type(value) == 'table' and not is_array(value) then
        local ret = {}
        local short = true
        for k, v in pairs(value) do
            local new_key = key .. self.separator .. k
            local val, sc, err = self:set(new_key, v, process)
            if err then return nil, false, err end
            if not sc then
                ret[k] = val
                short = false
            end
        end
        return ret, short, nil
    else
        local new_process, p_err = process:clone()
        if p_err then
            return nil, true, p_err
        end
        self.store[key] = new_process
        return self.store[key]:run(value)
    end
end

---Updates a value in the cache using existing process
---@param key string|table Key to update
---@param value any New value
---@return any value
---@return boolean short_circuit
---@return string? Error
function ActionCache:update(key, value)
    key = type(key) == 'string' and key or table.concat(key, self.separator)
    if type(value) == 'table' and not is_array(value) then
        local ret = {}
        local short = true
        for k, v in pairs(value) do
            local new_key = key .. self.separator .. k
            local val, sc, err = self:update(new_key, v)
            if err then return nil, true, err end
            if not sc then
                ret[k] = val
                short = false
            end
        end
        return ret, short, nil
    else
        local process = self.store[key]
        if process then
            return process:run(value)
        end
    end
    return nil, true, 'could not find process associated with key-value'
end

---Resets all processes in the cache
function ActionCache:reset()
    for _, process in pairs(self.store) do
        process:reset()
    end
end

---Checks if a key exists in the cache
---@param key string|table Key to check
---@return boolean exists
function ActionCache:has_key(key)
    key = type(key) == 'string' and key or table.concat(key, self.separator)
    return self.store[key] ~= nil
end

return ActionCache

