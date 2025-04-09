local sc = require 'fibers.utils.syscall'

--- Base Process class setup
---@class Process
local Process = {}
Process.__index = Process  -- Setup instance->class lookup

function Process.new()
    return setmetatable({}, Process)
end

---@param value any
---@return any
---@return boolean # Short-circuit flag
---@return string? Error
function Process:run(value)
    return nil, true, "run must be implemented by derived class"
end

---@return Process?
function Process:clone()
    error("clone must be implemented by derived class")
end

function Process:reset()
    error("reset must be implemented by derived class")
end

--- @class DiffTrigger: Process
--- @field threshold number
--- @field diff_method function
--- @field config table
local DiffTrigger = {}
DiffTrigger.__index = DiffTrigger
setmetatable(DiffTrigger, { __index = Process })

local function check_diff_args_valid(config)
    if config.initial_val and type(config.initial_val) ~= 'number' then
        return 'Initial value must be a number'
    end
    if config.diff_method ~= 'any-change' and type(config.threshold) ~= 'number' then
        return 'Threshold must be a number'
    end
end
---@param config table
---@return DiffTrigger?
---@return string? Error
function DiffTrigger.new(config)
    local initial_val = config.initial_val
    local diff_method = config.diff_method
    local threshold = config.threshold
    local valid_err = check_diff_args_valid(config)
    if valid_err then return nil, valid_err end
    local self = setmetatable({}, DiffTrigger)
    if diff_method == 'absolute' then
        self.diff_method = function(curr, last, threshold) return math.abs(curr - last) >= threshold end
    elseif diff_method == 'percent' then
        self.diff_method = function(curr, last, threshold) return (math.abs((curr - last) / last) * 100) >= threshold end
    elseif diff_method == 'any-change' then
        self.diff_method = function (curr, last) return curr ~= last end
    else
        return nil, "Diff method must be 'absolute', 'percent' or 'any-change'"
    end
    self.empty = (initial_val == nil)
    self.threshold = threshold
    self.last_val = initial_val or 0
    self.curr_val = initial_val
    self.config = config
    return self, nil
end

---@param value any
---@return any
---@return boolean # Short-circuit flag
---@return string? Error
function DiffTrigger:run(value)
    self.curr_val = value
    if self.empty or self.diff_method(self.curr_val, self.last_val, self.threshold) then
        self.last_val = value
        self.empty = false
        return value, false, nil
    end
    return nil, true, nil
end

---@return DiffTrigger?
---@return string?
function DiffTrigger:clone()
    return self.new(self.config)
end

function DiffTrigger:reset()
end

--- @class TimeTrigger: Process
--- @field duration number
--- @field config table
local TimeTrigger = {}
TimeTrigger.__index = TimeTrigger
setmetatable(TimeTrigger, { __index = Process })

---@param config table
---@return TimeTrigger?
---@return string? Error
function TimeTrigger.new(config)
    local duration = config.duration
    if duration == nil or type(duration) ~= "number" then return nil, "Duration must be a number" end
    local self = setmetatable({}, TimeTrigger)
    self.duration = duration
    self.timeout = sc.monotime() + duration
    self.config = config
    return self, nil
end

---@param value any
---@return any
---@return boolean # Short-circuit flag
---@return string? Error
function TimeTrigger:run(value)
    if sc.monotime() >= self.timeout then
        self.timeout = sc.monotime() + self.duration
        return value, false, nil
    end
    return nil, true, nil
end

---@return TimeTrigger?
---@return string? Error
function TimeTrigger:clone()
    return self.new(self.config)
end

function TimeTrigger:reset()
end

---@class DeltaValue: Process
---@field config table
local DeltaValue = {}
DeltaValue.__index = DeltaValue
setmetatable(DeltaValue, { __index = Process })

---@param config table
---@return DeltaValue
function DeltaValue.new(config)
    local self = setmetatable({}, DeltaValue)
    self.last_val = config.initial_val or 0
    self.config = config
    return self
end

---@param value any
---@return any
---@return boolean # Short-circuit flag
---@return string? Error
function DeltaValue:run(value)
    if type(value) ~= 'number' then return nil, nil, 'Value must be a number' end
    local difference = value - self.last_val
    self.curr_val = value
    return difference, false, nil
end

function DeltaValue:reset()
    self.last_val = self.curr_val or 0
end

---@return DeltaValue
function DeltaValue:clone()
    return DeltaValue.new(self.config)
end

---@class ProcessPipeline: Process
---@field process_blocks Process[]
local ProcessPipeline = {}
ProcessPipeline.__index = ProcessPipeline

---comment
---@param processing_block Process
---@return string? Error
function ProcessPipeline:add(processing_block)
    if processing_block == nil then return 'processing block cannot be nil' end
    table.insert(self.process_blocks, processing_block)
end

---@param value any
---@return any
---@return boolean # Short-circuit flag
---@return string? Error
function ProcessPipeline:run(value)
    local val = value
    local short = false
    local err = nil
    for _, process in ipairs(self.process_blocks) do
        val, short, err = process:run(val)
        if err or short then break end
    end
    if (not short) and (not err) then self.full_run = true end
    -- if not err and not short then self:reset() end
    return val, short, err
end

--- Reset only if the pipeline has output a value
--- without short circuiting
function ProcessPipeline:reset()
    if self.full_run then
        for _, process in ipairs(self.process_blocks) do
            process:reset()
        end
        self.full_run = false
    end
end

--- Reset whether the pipeline has output or not
function ProcessPipeline:force_reset()
    self.full_run = true
    self:reset()
end

---@return ProcessPipeline?
---@return string? Error
function ProcessPipeline:clone()
    local pipeline = setmetatable({ full_run = false, process_blocks = {} }, ProcessPipeline)
    for _, process_block in ipairs(self.process_blocks) do
        local process, err = process_block:clone()
        if not process or err then
            return nil, err
        end
        pipeline:add(process)
    end

    return pipeline, nil
end
--- @param process_config table
--- @return ProcessPipeline?
--- @return string? Error
local function new_process_pipeline(process_config)
    if process_config == nil then return nil, 'Cannot create a process pipeline with no config' end
    local self = setmetatable({}, ProcessPipeline)
    self.process_blocks = {}
    self.full_run = false
    return self
end

return {
    DiffTrigger = DiffTrigger,
    TimeTrigger = TimeTrigger,
    DeltaValue = DeltaValue,
    new_process_pipeline = new_process_pipeline
}
