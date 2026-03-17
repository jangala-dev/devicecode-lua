-- services/metrics/processing.lua
--
-- Processing pipeline blocks for the metrics service.
--
-- Each block class holds only configuration (logic). Runtime state is kept in a
-- separate table created by :new_state() and passed explicitly to :run() and
-- :reset().  This allows a single pipeline object to be shared across many
-- metric endpoints while maintaining fully isolated per-endpoint state.
--
-- Block interface:
--   block:new_state()               -> state_table
--   block:run(value, state)         -> value, short_circuit, error
--   block:reset(state)              -> nil
--
-- ProcessPipeline wraps a list of blocks and exposes the same interface:
--   pipeline:new_state()            -> state_table  {full_run, blocks={...}}
--   pipeline:run(value, state)      -> value, short_circuit, error
--   pipeline:reset(state)           -> nil   (only resets when full_run == true)
--   pipeline:force_reset(state)     -> nil   (reset unconditionally)
--   pipeline:add(block)             -> error?

local runtime = require 'fibers.runtime'

-------------------------------------------------------------------------------
-- Base Process (documentation only; not used at runtime)
-------------------------------------------------------------------------------

---@class Process
---@field new_state  fun(self: Process): table
---@field run        fun(self: Process, value: any, state: table): any, boolean, string?
---@field reset      fun(self: Process, state: table)

-------------------------------------------------------------------------------
-- DiffTrigger
-------------------------------------------------------------------------------

--- Passes a value only when the change from the last-published value exceeds a
--- threshold.  Three diff methods are supported:
---   "absolute"   - abs(curr - last) >= threshold
---   "percent"    - abs((curr - last) / last) * 100 >= threshold
---   "any-change" - curr ~= last
---
---@class DiffTrigger
---@field threshold  number
---@field diff_fn    function
---@field config     table
local DiffTrigger = {}
DiffTrigger.__index = DiffTrigger

local function check_diff_args_valid(config)
    if config.initial_val ~= nil and type(config.initial_val) ~= 'number' then
        return 'Initial value must be a number'
    end
    if config.diff_method ~= 'any-change' and type(config.threshold) ~= 'number' then
        return 'Threshold must be a number'
    end
end

---@param config table
---@return DiffTrigger?
---@return string? error
function DiffTrigger.new(config)
    local valid_err = check_diff_args_valid(config)
    if valid_err then return nil, valid_err end

    local self = setmetatable({}, DiffTrigger)
    self.config = config
    self.threshold = config.threshold

    local dm = config.diff_method
    if dm == 'absolute' then
        self.diff_fn = function(curr, last, threshold)
            return math.abs(curr - last) >= threshold
        end
    elseif dm == 'percent' then
        self.diff_fn = function(curr, last, threshold)
            return (math.abs((curr - last) / last) * 100) >= threshold
        end
    elseif dm == 'any-change' then
        self.diff_fn = function(curr, last)
            return curr ~= last
        end
    else
        return nil, "Diff method must be 'absolute', 'percent' or 'any-change'"
    end
    return self, nil
end

---@return table
function DiffTrigger:new_state()
    return {
        empty    = (self.config.initial_val == nil),
        last_val = self.config.initial_val or 0,
        curr_val = nil,
    }
end

---@param value any
---@param state table
---@return any
---@return boolean short_circuit
---@return string? error
function DiffTrigger:run(value, state)
    state.curr_val = value
    if state.empty or self.diff_fn(state.curr_val, state.last_val, self.threshold) then
        state.last_val = value
        state.empty = false
        return value, false, nil
    end
    return nil, true, nil
end

--- No-op: DiffTrigger does not reset last_val on publish.
---@param state table
function DiffTrigger:reset(state) end -- luacheck: ignore

-------------------------------------------------------------------------------
-- TimeTrigger
-------------------------------------------------------------------------------

--- Passes a value only when the elapsed time since the last pass exceeds
--- `duration` seconds.
---
---@class TimeTrigger
---@field duration number
---@field config   table
local TimeTrigger = {}
TimeTrigger.__index = TimeTrigger

---@param config table
---@return TimeTrigger?
---@return string? error
function TimeTrigger.new(config)
    if type(config.duration) ~= 'number' then
        return nil, 'Duration must be a number'
    end
    local self    = setmetatable({}, TimeTrigger)
    self.duration = config.duration
    self.config   = config
    return self, nil
end

---@return table
function TimeTrigger:new_state()
    return { timeout = runtime.now() + self.duration }
end

---@param value any
---@param state table
---@return any
---@return boolean short_circuit
---@return string? error
function TimeTrigger:run(value, state)
    if runtime.now() >= state.timeout then
        state.timeout = runtime.now() + self.duration
        return value, false, nil
    end
    return nil, true, nil
end

---@param state table
function TimeTrigger:reset(state) end -- luacheck: ignore

-------------------------------------------------------------------------------
-- DeltaValue
-------------------------------------------------------------------------------

--- Replaces the raw value with the difference from the last-published value.
--- Requires numeric input.
---
---@class DeltaValue
---@field config table
local DeltaValue = {}
DeltaValue.__index = DeltaValue

---@param config table
---@return DeltaValue?
---@return string? error
function DeltaValue.new(config)
    if config.initial_val ~= nil and type(config.initial_val) ~= 'number' then
        return nil, 'Initial value must be a number'
    end
    local self = setmetatable({}, DeltaValue)
    self.config = config
    return self, nil
end

---@return table
function DeltaValue:new_state()
    return {
        last_val = self.config.initial_val or 0,
        curr_val = nil,
    }
end

---@param value any
---@param state table
---@return any
---@return boolean short_circuit
---@return string? error
function DeltaValue:run(value, state)
    if type(value) ~= 'number' then
        return nil, false, 'Value must be a number'
    end
    local difference = value - state.last_val
    state.curr_val = value
    return difference, false, nil
end

--- On reset, advance last_val to curr_val so the next delta is computed from
--- the most-recently-published sample.
---@param state table
function DeltaValue:reset(state)
    state.last_val = state.curr_val or 0
end

-------------------------------------------------------------------------------
-- ProcessPipeline
-------------------------------------------------------------------------------

---@class ProcessPipeline
---@field process_blocks table
local ProcessPipeline = {}
ProcessPipeline.__index = ProcessPipeline

---@return ProcessPipeline
local function new_process_pipeline()
    return setmetatable({ process_blocks = {} }, ProcessPipeline)
end

--- Append a processing block to the pipeline.
---@param block any
---@return string? error
function ProcessPipeline:add(block)
    if block == nil then return 'processing block cannot be nil' end
    table.insert(self.process_blocks, block)
end

--- Create a fresh state table for this pipeline (and all its blocks).
---@return table
function ProcessPipeline:new_state()
    local state = { full_run = false, blocks = {} }
    for i, block in ipairs(self.process_blocks) do
        state.blocks[i] = block:new_state()
    end
    return state
end

--- Run the pipeline, passing value through each block sequentially.
--- Stops early if any block short-circuits or returns an error.
---@param value any
---@param state table
---@return any
---@return boolean short_circuit
---@return string? error
function ProcessPipeline:run(value, state)
    local val   = value
    local short = false
    local err   = nil

    for i, block in ipairs(self.process_blocks) do
        val, short, err = block:run(val, state.blocks[i])
        if err or short then break end
    end

    if not short and not err then
        state.full_run = true
    end

    return val, short, err
end

--- Reset block states, but only when the pipeline produced a published value
--- (i.e. ran to completion without short-circuiting).
---@param state table
function ProcessPipeline:reset(state)
    if state.full_run then
        for i, block in ipairs(self.process_blocks) do
            block:reset(state.blocks[i])
        end
        state.full_run = false
    end
end

--- Reset regardless of whether the pipeline produced a published value.
---@param state table
function ProcessPipeline:force_reset(state)
    state.full_run = true
    self:reset(state)
end

return {
    DiffTrigger          = DiffTrigger,
    TimeTrigger          = TimeTrigger,
    DeltaValue           = DeltaValue,
    new_process_pipeline = new_process_pipeline,
}
