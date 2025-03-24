-- Base class setup
local Trigger = {}
Trigger.__index = Trigger  -- Setup instance->class lookup

function Trigger.new()
    return setmetatable({}, Trigger)
end

function Trigger:update_val()
    error("update_val must be implemented by derived class")
end

function Trigger:is_active()
    error("is_active must be implemented by derived class")
end

function Trigger:clone()
    error("clone must be implemented by derived class")
end

function Trigger:reset()
    error("reset must be implemented by derived class")
end

-- AlwaysTrigger class setup
local AlwaysTrigger = {}
AlwaysTrigger.__index = AlwaysTrigger
setmetatable(AlwaysTrigger, { __index = Trigger })

function AlwaysTrigger.new()
    return setmetatable({}, AlwaysTrigger)
end

function AlwaysTrigger:update_val()
    return
end

function AlwaysTrigger:is_active()
    return true
end

function AlwaysTrigger:clone()
    return AlwaysTrigger.new()
end

function AlwaysTrigger:reset()
    return
end

-- DiffTrigger class setup
local DiffTrigger = {}
DiffTrigger.__index = DiffTrigger
setmetatable(DiffTrigger, { __index = Trigger })

function DiffTrigger.new(config)
    local initial_val = config.initial_val
    local diff_method = config.diff_method
    local threshold = config.threshold
    if initial_val and type(initial_val) ~= 'number' then return nil, "Initial value must be a number" end
    if threshold and type(threshold) ~= 'number' or threshold == nil then return "Threshold value must be a number" end
    local self = setmetatable({}, DiffTrigger)
    if diff_method == 'absolute' then
        self.diff_method = function(curr, last) return math.abs(curr - last) end
    elseif diff_method == 'percent' then
        self.diff_method = function(curr, last) return math.abs((curr - last) / last) * 100 end
    else
        return nil, "Diff method must be 'absolute' or 'percent'"
    end
    self.empty = (initial_val == nil)
    self.threshold = threshold
    self.last_val = initial_val or 0
    self.curr_val = initial_val
    return self
end

function DiffTrigger:clone()
    return setmetatable(
        { last_val = self.last_val, curr_val = self.curr_val, diff_method = self.diff_method, threshold = self.threshold },
        DiffTrigger)
end

function DiffTrigger:reset()
    self.empty = false
    self.last_val = self.curr_val
end

function DiffTrigger:update_val(new_val)
    self.curr_val = new_val
end

function DiffTrigger:is_active()
    if self.empty then return true end
    local diff = self.diff_method(self.curr_val, self.last_val)
    if diff >= self.threshold then
        return true
    end
    return false
end

-- ArrayDiffTrigger class setup
-- local ArrayDiffTrigger = {}
-- ArrayDiffTrigger.__index = ArrayDiffTrigger
-- setmetatable(ArrayDiffTrigger, { __index = Trigger })

-- function ArrayDiffTrigger.new(diff_method, thresholds, initial_vals, check_mode)
--     if type(initial_vals) ~= 'table' then return nil, "Initial values must be a list" end
--     if #thresholds ~= #initial_vals then return nil, "Thresholds must match initial values" end
--     local self = setmetatable({}, ArrayDiffTrigger)
--     if diff_method == 'absolute' then
--         self.diff_method = function(curr, last) return math.abs(curr - last) end
--     elseif diff_method == 'percent' then
--         self.diff_method = function(curr, last) return math.abs((curr - last) / last) * 100 end
--     else
--         return nil, "Diff method must be 'absolute' or 'percent'"
--     end
--     self.threshold = thresholds
--     self.init_vals = initial_vals
--     self.last_vals = initial_vals
--     self.curr_vals = initial_vals
--     self.check_mode = check_mode or 'any'
--     return self
-- end

-- function ArrayDiffTrigger:clone()
--     return setmetatable(
--         {
--             last_vals = self.last_vals,
--             curr_vals = self.curr_vals,
--             diff_method = self.diff_method,
--             threshold = self.threshold,
--             check_mode = self.check_mode
--         },
--         ArrayDiffTrigger)
-- end

-- function ArrayDiffTrigger:reset()
--     self.last_vals = self.curr_vals
-- end

-- function ArrayDiffTrigger:update_val(new_vals)
--     if type(new_vals) ~= 'table' then return "New values must be a list" end
--     if #new_vals ~= #self.curr_vals then return "New values must match initial values" end
--     self.curr_vals = new_vals
-- end

-- function ArrayDiffTrigger:is_active()
--     local active_count = 0
--     for i, curr_val in ipairs(self.curr_vals) do
--         local diff = self.diff_method(curr_val, self.last_vals[i])
--         if diff >= self.threshold[i] then
--             if self.check_mode == 'any' then
--                 return true
--             end
--             active_count = active_count + 1
--         end
--     end
--     if self.check_mode == 'all' and active_count == #self.curr_vals then
--         return true
--     end
--     return false
-- end

-- TimeTrigger class setup
local TimeTrigger = {}
TimeTrigger.__index = TimeTrigger
setmetatable(TimeTrigger, { __index = Trigger })

function TimeTrigger.new(config)
    local duration = config.duration
    if duration == nil or type(duration) ~= "number" then return nil, "Duration must be a number" end
    local self = setmetatable({}, TimeTrigger)
    self.duration = duration
    self.timeout = os.time() + duration
    return self
end

function TimeTrigger:update_val()
    return
end

function TimeTrigger:is_active()
    if os.time() >= self.timeout then
        return true
    end
    return false
end

function TimeTrigger:clone()
    return setmetatable({ duration = self.duration, timeout = self.timeout }, TimeTrigger)
end

function TimeTrigger:reset()
    self.timeout = os.time() + self.duration
end

return {
    -- Trigger = Trigger,
    AlwaysTrigger = AlwaysTrigger,
    DiffTrigger = DiffTrigger,
    -- ArrayDiffTrigger = ArrayDiffTrigger,
    TimeTrigger = TimeTrigger
}
