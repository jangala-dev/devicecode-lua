-- fibers/timer.lua

--- Monotonic timer built on a binary min-heap.
---@module 'fibers.timer'

---@class TimerNode
---@field time number       # absolute due time (monotonic seconds)
---@field obj any           # scheduled payload
---@field index integer|nil # current heap index, nil when not queued

---@alias TimerCancel fun(): boolean

local floor, huge = math.floor, math.huge

--- Simple min-heap keyed by node.time.
---@class Heap
---@field heap TimerNode[]
---@field size integer
local Heap = {}
Heap.__index = Heap

---@return Heap
local function new_heap()
	return setmetatable({ heap = {}, size = 0 }, Heap)
end

---@param i integer
---@param j integer
function Heap:swap(i, j)
	local heap = self.heap
	heap[i], heap[j] = heap[j], heap[i]
	heap[i].index = i
	heap[j].index = j
end

---@param node TimerNode
function Heap:push(node)
	local size = self.size + 1
	self.size = size
	node.index = size
	self.heap[size] = node
	self:heapify_up(size)
end

---@return TimerNode|nil
function Heap:pop()
	local size = self.size
	if size == 0 then
		return nil
	end

	local heap = self.heap
	local root = heap[1]
	root.index = nil

	if size == 1 then
		heap[1] = nil
		self.size = 0
		return root
	end

	local last = heap[size]
	heap[size] = nil
	self.size = size - 1
	heap[1] = last
	last.index = 1
	self:heapify_down(1)

	return root
end

---@param node TimerNode
---@return boolean
function Heap:remove(node)
	local idx = node.index
	if type(idx) ~= 'number' or idx < 1 or idx > self.size then
		return false
	end

	local heap = self.heap
	if heap[idx] ~= node then
		return false
	end

	local size = self.size
	node.index = nil

	if idx == size then
		heap[size] = nil
		self.size = size - 1
		return true
	end

	local last = heap[size]
	heap[size] = nil
	self.size = size - 1
	heap[idx] = last
	last.index = idx

	local parent = floor(idx / 2)
	if idx > 1 and heap[idx].time < heap[parent].time then
		self:heapify_up(idx)
	else
		self:heapify_down(idx)
	end

	return true
end

---@param idx integer
function Heap:heapify_up(idx)
	local heap = self.heap
	while idx > 1 do
		local parent = floor(idx / 2)
		if heap[parent].time <= heap[idx].time then
			break
		end
		self:swap(parent, idx)
		idx = parent
	end
end

---@param idx integer
function Heap:heapify_down(idx)
	local heap = self.heap
	local size = self.size

	while true do
		local left     = 2 * idx
		local right    = left + 1
		local smallest = idx

		if left <= size and heap[left].time < heap[smallest].time then
			smallest = left
		end
		if right <= size and heap[right].time < heap[smallest].time then
			smallest = right
		end

		if smallest == idx then
			break
		end

		self:swap(idx, smallest)
		idx = smallest
	end
end

---@class Timer
---@field now number  # current timer time (monotonic seconds)
---@field heap Heap
local Timer = {}
Timer.__index = Timer

--- Create a new timer instance.
---@param now number # initial monotonic time.
---@return Timer
local function new(now)
	return setmetatable({ now = now, heap = new_heap() }, Timer)
end

--- Schedule an object at absolute time t.
---@param t number   # absolute due time
---@param obj any    # payload to pass to the scheduler
---@return TimerCancel cancel # idempotent cancellation handle
function Timer:add_absolute(t, obj)
	local node = { time = t, obj = obj, index = nil }
	self.heap:push(node)

	local cancelled = false
	return function ()
		if cancelled then
			return false
		end

		cancelled = true
		local removed = self.heap:remove(node)
		node.obj = nil
		return removed
	end
end

--- Schedule an object after a delay from the current timer time.
---@param dt number  # delay in seconds from self.now
---@param obj any    # payload to pass to the scheduler
---@return TimerCancel cancel # idempotent cancellation handle
function Timer:add_delta(dt, obj)
	return self:add_absolute(self.now + dt, obj)
end

--- Get the time of the next scheduled entry, or math.huge if none exist.
---@return number
function Timer:next_entry_time()
	local heap = self.heap
	return heap.size > 0 and heap.heap[1].time or huge
end

--- Pop the next scheduled entry without dispatching it.
---@return TimerNode|nil
function Timer:pop()
	return self.heap:pop()
end

--- Advance the timer to time t and dispatch all due entries.
---@param t number        # new monotonic time
---@param sched { schedule: fun(self:any, obj:any) }
function Timer:advance(t, sched)
	local heap = self.heap

	while heap.size > 0 and t >= heap.heap[1].time do
		local node = assert(heap:pop()) -- non-nil since size>0
		local obj = node.obj
		node.obj = nil
		self.now = node.time
		sched:schedule(obj)
	end

	self.now = t
end

return { new = new }
