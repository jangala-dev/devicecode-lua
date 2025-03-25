local function is_array(t)
    if type(t) ~= 'table' then return false end
    local i = 0
    for _ in pairs(t) do
        i = i + 1
        if t[i] == nil then return false end
    end
    return true
end

local ActionCache = {}
ActionCache.__index = ActionCache

function ActionCache.new(separator)
    local self = setmetatable({}, ActionCache)
    self.separator = separator or string.char(31)
    self.store = {}
    return self
end

function ActionCache:set(key, value, process)
    key = type(key) == 'string' and key or table.concat(key, self.separator)
    if type(value) == 'table' and not is_array(value) then
        local ret = {}
        local short = true
        for k, v in pairs(value) do
            local new_key = key .. self.separator .. k
            local val, sc, err = self:set(new_key, v, process:clone())
            if err then return nil, nil, err end
            if not sc then
                ret[k] = val
                short = false
            end
        end
        return ret, short, nil
    else
        self.store[key] = process
        return process:run(value)
    end
end

function ActionCache:update(key, value)
    key = type(key) == 'string' and key or table.concat(key, self.separator)
    if type(value) == 'table' and not is_array(value) then
        local ret = {}
        local short = true
        for k, v in pairs(value) do
            local new_key = key .. self.separator .. k
            local val, sc, err = self:update(new_key, v)
            if err then return nil, nil, err end
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
end

function ActionCache:reset(key, value)
    key = type(key) == 'string' and key or table.concat(key, self.separator)
    if type(value) == 'table' and not is_array(value) then
        for k, v in pairs(value) do
            local new_key = key .. self.separator .. k
            self:reset(new_key, v)
        end
    else
        local process = self.store[key]
        if process then
            process:reset()
        end
    end
end

-- function ActionCache:get(key)
--     key = type(key) == 'string' and key or table.concat(key, self.separator)
--     local stored = self.store[key]

--     if stored and stored.trigger:is_active() then
--         stored.trigger:reset()
--         return stored.value
--     end
--     return nil
-- end
function ActionCache:has_key(key)
    key = type(key) == 'string' and key or table.concat(key, self.separator)
    return self.store[key] ~= nil
end

return ActionCache

