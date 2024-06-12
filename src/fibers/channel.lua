-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

--- fibers.channel module
-- Provides Concurrent ML style channels for communication between fibers.
-- @module fibers.channel

local op = require 'fibers.op'

local Fifo = {}
Fifo.__index = Fifo
local function new_fifo() return setmetatable({}, Fifo) end
function Fifo:push(x) table.insert(self, x) end

function Fifo:empty() return #self == 0 end

function Fifo:peek()
    assert(not self:empty()); return self[1]
end

function Fifo:pop()
    assert(not self:empty()); return table.remove(self, 1)
end

--- Channel class
-- Represents a communication channel between fibers.
-- @type Channel
local Channel = {}

--- Create a new Channel.
-- @treturn Channel The created Channel.
local function new()
    return setmetatable(
        { getq = new_fifo(), putq = new_fifo() },
        { __index = Channel })
end

--- Create a put operation for the Channel.
-- Make an operation that if and when it completes will rendezvous with
-- a receiver fiber to send VAL over the channel.
-- @param val The value to put into the Channel.
-- @treturn BaseOp The created put operation.
function Channel:put_op(val)
    local getq, putq = self.getq, self.putq
    local function try()
        while not getq:empty() do
            local remote = getq:pop()
            if remote.suspension:waiting() then
                remote.suspension:complete(remote.wrap, val)
                return true
            end
            -- Otherwise the remote suspension is already completed, in
            -- which case we did the right thing to pop off the dead
            -- suspension from the getq.
        end
        return false
    end
    local function block(suspension, wrap_fn)
        -- First, a bit of GC.
        while not putq:empty() and not putq:peek().suspension:waiting() do
            putq:pop()
        end
        -- We have suspended the current fiber; arrange for the fiber
        -- to be resumed by a get operation by adding it to the channel's
        -- putq.
        putq:push({ suspension = suspension, wrap = wrap_fn, val = val })
    end
    return op.new_base_op(nil, try, block)
end

--- Create a get operation for the Channel.
-- Make an operation that if and when it completes will rendezvous with
-- a sender fiber to receive one value from the channel.
-- @treturn BaseOp The created get operation.
function Channel:get_op()
    local getq, putq = self.getq, self.putq
    local function try()
        while not putq:empty() do
            local remote = putq:pop()
            if remote.suspension:waiting() then
                remote.suspension:complete(remote.wrap)
                return true, remote.val
            end
            -- Otherwise the remote suspension is already completed, in
            -- which case we did the right thing to pop off the dead
            -- suspension from the putq.
        end
        return false
    end
    local function block(suspension, wrap_fn)
        -- First, a bit of GC.
        while not getq:empty() and not getq:peek().suspension:waiting() do
            getq:pop()
        end
        -- We have suspended the current fiber; arrange for the fiber to
        -- be resumed by a put operation by adding it to the channel's
        -- getq.
        getq:push({ suspension = suspension, wrap = wrap_fn })
    end
    return op.new_base_op(nil, try, block)
end

--- Put a message into the Channel.
-- Send message on the channel.  If there is already another fiber
-- waiting to receive a message on this channel, give it our message and
-- continue.  Otherwise, block until a receiver becomes available.
-- @tparam any message The message to put into the Channel.
function Channel:put(message)
    self:put_op(message):perform()
end

--- Get a message from the Channel.
-- Receive a message from the channel and return it.  If there is
-- already another fiber waiting to send a message on this channel, take
-- its message directly.  Otherwise, block until a sender becomes
-- available.
-- @treturn any The message retrieved from the Channel.
function Channel:get()
    return self:get_op():perform()
end

--- @export
return {
    new = new
}
