-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

--- fibers.cond module.
-- This module implements a condition variable, a rendezvous point for
-- fibers waiting for or announcing the occurrence of an event.
-- @module fibers.cond

local op = require 'fibers.op'

--- Cond class.
-- Represents a condition variable.
-- @type Cond
local Cond = {}

--- Create a new condition variable.
-- @treturn Cond The new condition variable.
local function new()
    return setmetatable({ waitq = {} }, { __index = Cond })
end

--- Create a new operation that will put the fiber into a wait state on the condition variable.
-- @treturn operation The created operation.
function Cond:wait_op()
    local function try() return not self.waitq end
    local function gc()
        local i = 1
        while i <= #self.waitq do
            if self.waitq[i].suspension:waiting() then
                i = i + 1
            else
                table.remove(self.waitq, i)
            end
        end
    end
    local function block(suspension, wrap_fn)
        gc()
        table.insert(self.waitq, { suspension = suspension, wrap = wrap_fn })
    end
    return op.new_base_op(nil, try, block)
end

--- Put the fiber into a wait state on the condition variable.
function Cond:wait() return self:wait_op():perform() end

--- Wake up all fibers that are waiting on this condition variable.
function Cond:signal()
    if self.waitq ~= nil then
        for _, remote in ipairs(self.waitq) do
            if remote.suspension:waiting() then
                remote.suspension:complete(remote.wrap)
            end
        end
        self.waitq = nil
    end
end

return {
    new = new
}
