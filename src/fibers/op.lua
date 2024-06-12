-- (c) Snabb project
-- (c) Jangala

-- Use of this source code is governed by the XXXXXXXXX license; see COPYING.

--- fibers.op module
-- Provides Concurrent ML style operations for managing concurrency.
-- @module fibers.op

local fiber = require 'fibers.fiber'

local Suspension = {}
Suspension.__index = Suspension

local CompleteTask = {}
CompleteTask.__index = CompleteTask

function Suspension:waiting() return self.state == 'waiting' end

function Suspension:complete(wrap, val)
    assert(self:waiting())
    self.state = 'synchronized'
    self.wrap = wrap
    self.val = val
    self.sched:schedule(self)
end

function Suspension:complete_and_run(wrap, val)
    assert(self:waiting())
    self.state = 'synchronized'
    return self.fiber:resume(wrap, val)
end

function Suspension:complete_task(wrap, val)
    return setmetatable({ suspension = self, wrap = wrap, val = val }, CompleteTask)
end

function Suspension:run()
    assert(not self:waiting())
    return self.fiber:resume(self.wrap, self.val)
end

local function new_suspension(sched, fib)
    return setmetatable(
        { state = 'waiting', sched = sched, fiber = fib },
        Suspension)
end

--- A complete task is a task that when run, completes a suspension, if
--- the suspension hasn't been completed already.  There can be multiple
--- complete tasks for a given suspension, if the suspension can complete
--- in multiple ways (e.g. via a choice op).
function CompleteTask:run()
    if self.suspension:waiting() then
        -- Use complete-and-run so that the fiber runs in this turn.
        self.suspension:complete_and_run(self.wrap, self.val)
    end
end

--- A complete task can also be cancelled, which makes it complete with a
--- call to "error".
-- @param reason A string describing the reason for the cancellation
function CompleteTask:cancel(reason)
    if self.suspension:waiting() then
        self.suspension:complete(error, reason or 'cancelled')
    end
end

--- BaseOp class
-- Represents a base operation.
-- @type BaseOp
local BaseOp = {}
BaseOp.__index = BaseOp

--- Create a new base operation.
-- @tparam function wrap_fn The wrap function.
-- @tparam function try_fn The try function.
-- @tparam function block_fn The block function.
-- @treturn BaseOp The created base operation.
local function new_base_op(wrap_fn, try_fn, block_fn)
    if wrap_fn == nil then wrap_fn = function(val) return val end end
    return setmetatable(
        { wrap_fn = wrap_fn, try_fn = try_fn, block_fn = block_fn },
        BaseOp)
end

--- ChoiceOp class
-- Represents a choice operation.
-- @type ChoiceOp
local ChoiceOp = {}
ChoiceOp.__index = ChoiceOp
local function new_choice_op(base_ops)
    return setmetatable(
        { base_ops = base_ops },
        ChoiceOp)
end

--- Create a choice operation from the given operations.
-- @tparam vararg ops The operations.
-- @treturn ChoiceOp The created choice operation.
local function choice(...)
    local ops = {}
    -- Build a flattened list of choices that are all base ops.
    for _, op in ipairs({ ... }) do
        if op.base_ops then
            for _, base_op in ipairs(op.base_ops) do table.insert(ops, base_op) end
        else
            table.insert(ops, op)
        end
    end
    if #ops == 1 then return ops[1] end
    return new_choice_op(ops)
end

--- Wrap the base operation with the given function.
-- @tparam function f The function.
-- @treturn BaseOp The created base operation.
function BaseOp:wrap(f)
    local wrap_fn, try_fn, block_fn = self.wrap_fn, self.try_fn, self.block_fn
    return new_base_op(function(val) return f(wrap_fn(val)) end, try_fn, block_fn)
end

--- Wrap the choice operation with the given function.
-- @tparam function f The function.
-- @treturn ChoiceOp The created choice operation.
function ChoiceOp:wrap(f)
    local ops = {}
    for _, op in ipairs(self.base_ops) do table.insert(ops, op:wrap(f)) end
    return new_choice_op(ops)
end

local function block_base_op(sched, fib, op)
    op.block_fn(new_suspension(sched, fib), op.wrap_fn)
end

--- Perform the base operation.
-- @treturn vararg The value returned by the operation.
function BaseOp:perform()
    local success, val = self.try_fn()
    if success then return self.wrap_fn(val) end
    local wrap, new_val = fiber.suspend(block_base_op, self)
    return wrap(new_val)
end

local function block_choice_op(sched, fib, ops)
    local suspension = new_suspension(sched, fib)
    for _, op in ipairs(ops) do op.block_fn(suspension, op.wrap_fn) end
end

--- Perform the choice operation.
-- @treturn vararg The value returned by the operation.
function ChoiceOp:perform()
    local ops = self.base_ops
    local base = math.random(#ops)
    for i = 1, #ops do
        local op = ops[((i + base) % #ops) + 1]
        local success, val = op.try_fn()
        if success then return op.wrap_fn(val) end
    end
    local wrap, val = fiber.suspend(block_choice_op, ops)
    return wrap(val)
end

--- Perform the base operation or return the result of the function if the operation cannot be performed.
-- @tparam function f The function.
-- @treturn vararg The value returned by the operation or the function.
function BaseOp:perform_alt(f)
    fiber.yield() -- lessens race possibility
    local success, val = self.try_fn()
    if success then return self.wrap_fn(val) end
    return f()
end

--- Perform the choice operation or return the result of the function if the operation cannot be performed.
-- @tparam function f The function.
-- @treturn vararg The value returned by the operation or the function.
function ChoiceOp:perform_alt(f)
    fiber.yield() -- lessens race possibility
    local ops = self.base_ops
    local base = math.random(#ops)
    for i = 1, #ops do
        local op = ops[((i + base) % #ops) + 1]
        local success, val = op.try_fn()
        if success then return op.wrap_fn(val) end
    end
    return f()
end

return {
    new_base_op = new_base_op,
    choice = choice
}
