Cache = {}
Cache.__index = Cache

-- Constructor
function Cache.new(default_timeout, custom_time_func, separator)
    local self = setmetatable({}, Cache)
    self.default_timeout = default_timeout or 10
    self.time_func = custom_time_func or os.time
    self.separator = separator or string.char(31)
    self.store = {}
    return self
end

-- Utility function to check if a table is an array
local function is_array(table)
    local i = 0
    for _ in pairs(table) do
        i = i + 1
        if table[i] == nil then return false end
    end
    return true
end

-- Setting a value in the cache
function Cache:set(key, value, timeout)
    timeout = timeout or self.default_timeout
    if type(value) == 'table' then
        if is_array(value) then
            self.store[key] = {value=value, timestamp=self.time_func() + timeout}
        else
            for k, v in pairs(value) do
                self:set(key .. self.separator .. k, v, timeout)
            end
        end
    else
        self.store[key] = {value = value, timestamp=self.time_func() + timeout}
    end
end

-- Getting a value from the cache
function Cache:get(key)
    key = type(key) == 'string' and key or table.concat(key, self.separator)
    local item = self.store[key]
    if item and self.time_func() < item.timestamp then
        return item.value
    end
    return nil -- or a default value
end

return Cache