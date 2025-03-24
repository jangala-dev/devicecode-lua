local function is_array(t)
    if type(t) ~= 'table' then return false end
    local i = 0
    for _ in pairs(t) do
        i = i + 1
        if t[i] == nil then return false end
    end
    return true
end

local ReactiveCache = {}
ReactiveCache.__index = ReactiveCache

function ReactiveCache.new(separator)
    local self = setmetatable({}, ReactiveCache)
    self.separator = separator or string.char(31)
    self.store = {}
    return self
end

function ReactiveCache:set(key, value, trigger)
    key = type(key) == 'string' and key or table.concat(key, self.separator)
    if type(value) == 'table' and not is_array(value) then
        for k, v in pairs(value) do
            local new_key = key .. self.separator .. k
            return self:set(new_key, v, trigger:clone())
        end
    else
        self.store[key] = {
            value = value,
            trigger = trigger
        }
        trigger:update_val(value)
        if trigger:is_active() then
            trigger:reset()
            return value
        end
    end
end

function ReactiveCache:update(key, value)
    key = type(key) == 'string' and key or table.concat(key, self.separator)
    local stored = self.store[key]
    if stored then
        stored.value = value
        local update_err = stored.trigger:update_val(value)
        if update_err then return nil, update_err end
        if stored.trigger:is_active() then
            stored.trigger:reset()
            return value, nil
        end
    end
    return nil, nil
end

function ReactiveCache:get(key)
    key = type(key) == 'string' and key or table.concat(key, self.separator)
    local stored = self.store[key]

    if stored and stored.trigger:is_active() then
        stored.trigger:reset()
        return stored.value
    end
    return nil
end

function ReactiveCache:has_key(key)
    key = type(key) == 'string' and key or table.concat(key, self.separator)
    return self.store[key] ~= nil
end

return ReactiveCache

