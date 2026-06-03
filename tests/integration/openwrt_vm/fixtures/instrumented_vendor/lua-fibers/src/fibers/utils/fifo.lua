--- fibers.fifo module
-- A simple FIFO queue that can handle nil values.
-- @module fibers.fifo

local Fifo = {}
Fifo.__index = Fifo

--- Create a new FIFO queue.
-- @treturn Fifo The created FIFO queue.
local function new()
	return setmetatable({
		count = 0, -- total items ever pushed
		first = 1, -- index of first item
		items = {} -- storage table
	}, Fifo)
end

--- Push a value onto the queue.
-- @param x The value to push (can be nil)
function Fifo:push(x)
	self.count = self.count + 1
	self.items[self.count] = x
end

--- Check if the queue is empty.
-- @treturn boolean True if empty
function Fifo:empty()
	return self.first > self.count
end

--- Peek at the first item without removing it.
-- @return The first item
function Fifo:peek()
	assert(not self:empty(), 'queue is empty')
	return self.items[self.first]
end

--- Remove and return the first item.
-- @return The first item
function Fifo:pop()
	assert(not self:empty(), 'queue is empty')
	local val = self.items[self.first]
	self.items[self.first] = nil -- allow GC
	self.first = self.first + 1
	return val
end

--- Return the length of the queue.
-- @return The queue length
function Fifo:length()
	return self.count - self.first + 1
end

return {
	new = new
}
