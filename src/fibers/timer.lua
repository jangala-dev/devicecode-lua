-- (c) Jangala

-- Use of this source code is governed by the XXXXXXXXX license; see COPYING.

--- Binary Heap based timer.
-- Implements a Binary Heap based timer. This is a time based event scheduler,
-- used for efficiently scheduling and managing events.
-- @module fibers.timer

-- Required packages
local sc = require 'fibers.utils.syscall'

--- BinaryHeap class.
-- @type BinaryHeap
local BinaryHeap = {}
BinaryHeap.__index = BinaryHeap

--- BinaryHeap constructor.
-- @treturn BinaryHeap BinaryHeap instance.
function BinaryHeap:new()
    return setmetatable({heap = {}, size = 0}, BinaryHeap)
end

--- Pushes a node into the heap and heapify it.
-- @tparam table node The node to be pushed into the heap.
function BinaryHeap:push(node)
    self.size = self.size + 1
    self.heap[self.size] = node
    self:heapify_up(self.size)
end

--- Pops a node from the underlying heap and reheapifies. Does not advance the timer!
-- @treturn table|nil The root node popped from the heap, nil if the heap is empty.
function BinaryHeap:pop()
    if self.size == 0 then
        return nil
    end

    local root = self.heap[1]
    self.heap[1] = self.heap[self.size]
    self.size = self.size - 1
    self:heapify_down(1)
    return root
end

--- Maintains the heap property by moving a node up the heap.
-- @tparam number idx The index of the node in the heap array.
function BinaryHeap:heapify_up(idx)
    if idx <= 1 then
        return
    end

    local parent = math.floor(idx / 2)
    if self.heap[parent].time > self.heap[idx].time then
        self.heap[parent], self.heap[idx] = self.heap[idx], self.heap[parent]
        self:heapify_up(parent)
    end
end

--- Maintains the heap property by moving a node down the heap.
-- @tparam number idx The index of the node in the heap array.
function BinaryHeap:heapify_down(idx)
    local smallest = idx
    local left = 2 * idx
    local right = 2 * idx + 1

    if left <= self.size and self.heap[left].time < self.heap[smallest].time then
        smallest = left
    end
    if right <= self.size and self.heap[right].time < self.heap[smallest].time then
        smallest = right
    end
    if smallest ~= idx then
        self.heap[idx], self.heap[smallest] = self.heap[smallest], self.heap[idx]
        self:heapify_down(smallest)
    end
end

--- Timer class.
-- @type Timer
local Timer = {}
Timer.__index = Timer

--- Timer constructor.
-- @tparam[opt=now] number now The current time.
-- @treturn Timer New Timer instance.
local function new(now)
    now = now or sc.monotime()
    return setmetatable({now = now, heap = BinaryHeap:new()}, Timer)
end

--- Adds an object to the timer with an absolute time.
-- @tparam number t The absolute time.
-- @tparam any obj The object to add to the timer.
function Timer:add_absolute(t, obj)
    self.heap:push({time = t, obj = obj})
end

--- Adds an object to the timer with a delta time.
-- @tparam number dt The delta time.
-- @tparam any obj The object to add to the timer.
function Timer:add_delta(dt, obj)
    return self:add_absolute(self.now + dt, obj)
end

--- Returns the time of the next entry in the timer.
-- @treturn number The time of the next entry in the timer, or infinity if the heap is empty.
function Timer:next_entry_time()
    if self.heap.size == 0 then
        return 1/0 -- infinity
    end
    return self.heap.heap[1].time
end

--- Returns the time of the next entry in the timer.
-- @treturn number The time of the next entry in the timer, or infinity if the heap is empty.
function Timer:pop()
    return self.heap:pop()
end

--- Advances the timer, popping and scheduling objects from the heap as necessary.
-- @tparam number t The time to advance the timer to.
-- @tparam table sched The scheduler to use for scheduling objects.
function Timer:advance(t, sched)
    while self.heap.size > 0 and t >= self.heap.heap[1].time do
        local node = self.heap:pop()
        self.now = node.time
        sched:schedule(node.obj)
    end
    self.now = t
end

return {
    new = new
}