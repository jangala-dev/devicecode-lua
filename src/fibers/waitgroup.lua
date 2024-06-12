-- waitgroup.lua
local op = require 'fibers.op'
local cond = require 'fibers.cond'

local Waitgroup = {}
Waitgroup.__index = Waitgroup

local function new()
    local wg = setmetatable({ _counter = 0, _cond = cond.new() }, Waitgroup)
    return wg
end

function Waitgroup:add(count)
    self._counter = self._counter + count
    if self._counter < 0 then
        error("waitgroup counter goes negative")
    elseif self._counter == 0 then
        self._cond:signal()
    end
end

function Waitgroup:done()
    self:add(-1)
end

function Waitgroup:wait_op()
    local function try()
        return self._counter == 0
    end
    local function block(suspension, wrap_fn)
        if self._counter > 0 then
            -- Add suspension to the condition variable's wait queue.
            self._cond.waitq[#self._cond.waitq + 1] = { suspension = suspension, wrap = wrap_fn }
        end
    end
    return op.new_base_op(nil, try, block)
end

function Waitgroup:wait()
    self:wait_op():perform()
end

return {
    new = new
}
