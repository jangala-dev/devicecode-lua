local sleep = require "fibers.sleep"

---Recursively merges values from new table into original table
---@param orig any Original value
---@param new any New value to merge
---@return any
local function merge_values(orig, new)
    if type(orig) == "table" and type(new) == "table" then
        for k, v in pairs(new) do
            orig[k] = merge_values(orig[k], v)
        end
    else
        return new
    end
end

---@class TimedCache
---@field store table Cache storage
---@field time_method function Function to get current time
---@field period number Time period between cache flushes
---@field next_deadline number Next time to flush cache
local TimedCache = {}
TimedCache.__index = TimedCache

---Creates a new TimedCache instance
---@param period number Time period between cache flushes
---@param time_method function Function to get current time
---@return TimedCache?
---@return string? Error
function TimedCache.new(period, time_method)
    if period == nil then return nil, "a time period value must be given" end
    local self = setmetatable({}, TimedCache)
    self.store = {}
    self.time_method = time_method
    self.period = period
    self.next_deadline = self.time_method() + period

    return self, nil
end

---Sets a value in the cache
---@param key string[]|string Key to store value under
---@param value any Value to store
function TimedCache:set(key, value)
    if type(key) ~= "table" then key = { key } end
    local sub_table = self.store
    for i, part in ipairs(key) do
        if not sub_table[part] then
            sub_table[part] = {}
        end
        if i < #key then sub_table = sub_table[part] end
    end
    local end_part = key[#key]
    sub_table[end_part] = merge_values(sub_table[end_part], value)
end

---Creates a get op that sleeps until next deadline then returns and clears cache
---@return BaseOp
function TimedCache:get_op()
    return sleep.sleep_until_op(self.next_deadline):wrap(function ()
        local ret_store = self.store
        self.store = {}
        self.next_deadline = self.time_method() + self.period
        return ret_store
    end)
end

return TimedCache
