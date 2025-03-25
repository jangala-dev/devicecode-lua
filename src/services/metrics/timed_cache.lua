local sleep = require "fibers.sleep"

local function is_array(t)
    if type(t) ~= 'table' then return false end
    local i = 0
    for _ in pairs(t) do
        i = i + 1
        if t[i] == nil then return false end
    end
    return true
end

local function merge_values(orig, new)
    if type(orig) == "table" and type(new) == "table" then
        for k, v in pairs(new) do
            orig[k] = merge_values(orig[k], v)
        end
    else
        return new
    end
end

local TimedCache = {}
TimedCache.__index = TimedCache

function TimedCache.new(period, time_method, seperator)
    if period == nil then return nil, "a time period value must be given" end
    local self = setmetatable({}, TimedCache)
    self.store = {}
    self.time_method = time_method
    self.next_deadline = self.time_method() + period
    self.seperator = seperator or string.char(31)

    return self, nil
end

function TimedCache:set(key, value)
    if not self.store[key] then
        self.store[key] = value
    else
        self.store[key] = merge_values(self.store[key], value)
    end
end

function TimedCache:get_op()
    return sleep.sleep_until_op(self.next_deadline):wrap(function ()
        local ret_store = self.store
        self.store = {}
        return ret_store
    end)
end
