---@alias CacheKey string|string[]
---@alias CacheEntry {value: any, timestamp: number, timeout: number}

---@class Cache
---@field default_timeout number
---@field time_func function
---@field separator string
---@field store table<string, CacheEntry>
local Cache = {}
Cache.__index = Cache

--- Cache constructor
---@param default_timeout number?
---@param custom_time_func function?
---@param separator string?
---@return Cache
local function new(default_timeout, custom_time_func, separator)
    local self = setmetatable({}, Cache)
    self.default_timeout = default_timeout or 10
    self.time_func = custom_time_func or os.time
    self.separator = separator or string.char(31)
    self.store = {}
    return self
end

--- Setting a value in the cache
---@param key string
---@param value any
---@param timeout number?
function Cache:set(key, value, timeout)
    timeout = timeout or self.default_timeout
    -- if type(value) == 'table' then
    --     if is_array(value) then
    --         self.store[key] = {value=value, timestamp=self.time_func() + timeout, timeout = timeout}
    --     else
    --         for k, v in pairs(value) do
    --             self:set(key .. self.separator .. k, v, timeout)
    --         end
    --     end
    -- else
    --     self.store[key] = {value = value, timestamp=self.time_func(), timeout = timeout}
    -- end
    self.store[key] = {value = value, timestamp=self.time_func(), timeout = timeout}
end

--- Getting a value from the cache
---@param key CacheKey
---@param timeout number?
---@return any
function Cache:get(key, timeout)
    if type(key) ~= 'string' then
        key = table.concat(key, self.separator)
    end
    local item = self.store[key]
    if item then
        timeout = timeout or item.timeout
        if self.time_func() < (item.timestamp + timeout) then
            return item.value
        end
    end
    return nil -- or a default value
end

return {
    new = new,
    Cache = Cache
}
