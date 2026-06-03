-- fibers/sched.lua

--- Core cooperative scheduler for fiber tasks.
---@module 'fibers.sched'

local time  = require 'fibers.utils.time'
local timer = require 'fibers.timer'

local MAX_SLEEP_TIME = 10

--- A runnable task with a :run() method invoked by the scheduler.
---@class Task
---@field run fun(self: Task)

--- A source of tasks (timers, pollers, etc.) that can enqueue work on a scheduler.
---@class TaskSource
---@field schedule_tasks fun(self: TaskSource, sched: Scheduler, now: number)
---@field cancel_all_tasks fun(self: TaskSource, sched: Scheduler)|nil
---@field wait_for_events fun(self: TaskSource, sched: Scheduler, now: number, timeout: number)|nil

--- Main scheduler state and API.
---@class Scheduler
---@field next Task[]              # tasks runnable next turn
---@field cur Task[]               # tasks being run this turn
---@field sources TaskSource[]     # timer, poller, etc.
---@field wheel Timer              # timer wheel using the same clock
---@field maxsleep number          # maximum sleep interval in seconds
---@field get_time fun(): number   # monotonic time source
---@field event_waiter TaskSource|nil  # single source used for blocking waits (if any)
---@field done boolean
local Scheduler = {}
Scheduler.__index = Scheduler

--- Create a new scheduler instance.
---@param get_time? fun(): number # monotonic time source (defaults to fibers.utils.time.monotonic)
---@return Scheduler
local function new(get_time)
	local now_src = get_time or time.monotonic
	local now     = now_src()

	local ret = setmetatable({
		next         = {},
		cur          = {},
		sources      = {},
		wheel        = timer.new(now),
		maxsleep     = MAX_SLEEP_TIME,
		get_time     = now_src,
		event_waiter = nil,
		done         = false,
	}, Scheduler)

	--- Timer source: advances the wheel and schedules due tasks.
	---@class TimerTaskSource : TaskSource
	---@field wheel Timer
	local timer_task_source = { wheel = ret.wheel }

	--- Advance the timer wheel and schedule any due tasks.
	---@param sched Scheduler
	---@param now_ number
	function timer_task_source:schedule_tasks(sched, now_)
		self.wheel:advance(now_, sched)
	end

	function timer_task_source:cancel_all_tasks()
	end

	ret:add_task_source(timer_task_source)
	return ret
end

--- Register a task source with this scheduler.
--- A source must implement :schedule_tasks(sched, now).
--- If the source implements :wait_for_events, it becomes the scheduler's
--- sole event waiter (overwriting any previous one).
---@param source TaskSource
function Scheduler:add_task_source(source)
	table.insert(self.sources, source)
	if source.wait_for_events then
		self.event_waiter = source
	end
end

--- Schedule a task to be run on the next turn.
---@param task Task
function Scheduler:schedule(task)
	table.insert(self.next, task)
end

--- Get current monotonic time from the scheduler's clock source.
---@return number
function Scheduler:monotime()
	return self.get_time()
end

--- Get the last time observed by the timer wheel.
---@return number
function Scheduler:now()
	return self.wheel.now
end

--- Schedule a task at an absolute time.
---@param t number # absolute time on the scheduler clock
---@param task Task
function Scheduler:schedule_at_time(t, task)
	return self.wheel:add_absolute(t, task)
end

--- Schedule a task after a delay from the wheel's current time.
---@param dt number # delay in seconds
---@param task Task
function Scheduler:schedule_after_sleep(dt, task)
	return self.wheel:add_delta(dt, task)
end

--- Ask all registered sources to enqueue any ready tasks.
---@param now number
function Scheduler:schedule_tasks_from_sources(now)
	for i = 1, #self.sources do
		self.sources[i]:schedule_tasks(self, now)
	end
end

--- Run all tasks currently scheduled as runnable.
--- If now is nil, the current monotonic time is used.
---@param now? number
function Scheduler:run(now)
	if now == nil then
		now = self:monotime()
	end

	self:schedule_tasks_from_sources(now)

	self.cur, self.next = self.next, self.cur

	for i = 1, #self.cur do
		local task = self.cur[i]
		self.cur[i] = nil
		task:run()
	end
end

--- Compute the next time the scheduler may need to wake.
--- If there are runnable tasks, returns now() (do not sleep).
--- Otherwise defers to the timer wheel, which returns a time or math.huge.
---@return number
function Scheduler:next_wake_time()
	if #self.next > 0 then
		return self:now()
	end
	return self.wheel:next_entry_time()
end

--- Block until the next event or timeout.
--- Uses an event_waiter (e.g. poller) if present, otherwise sleeps.
function Scheduler:wait_for_events()
	local now       = self:monotime()
	local next_time = self:next_wake_time()

	local timeout = math.min(self.maxsleep, next_time - now)
	if timeout < 0 then timeout = 0 end

	if self.event_waiter then
		self.event_waiter:wait_for_events(self, now, timeout)
	else
		-- No poller installed; fall back to process-blocking sleep.
		time._block(timeout)
	end
end

--- Request that the scheduler main loop stops after the current iteration.
function Scheduler:stop()
	self.done = true
end

--- Run the scheduler main loop until stopped.
--- Repeatedly waits for events and runs ready tasks.
function Scheduler:main()
	self.done = false
	repeat
		self:wait_for_events()
		self:run(self:monotime())
	until self.done
end

--- Attempt to drain runnable work and ask sources to cancel outstanding tasks.
--- Sources are given an opportunity to cancel pending work; the scheduler
--- continues to drive sources (including timers) while draining.
--- Returns true if the runnable queue is drained within the iteration limit.
---@return boolean drained # true if work queue drained, false on iteration limit
function Scheduler:shutdown()
	for _ = 1, 100 do
		for i = 1, #self.sources do
			local src = self.sources[i]
			if src.cancel_all_tasks then
				src:cancel_all_tasks(self)
			end
		end

		if #self.next == 0 then return true end

		self:run()
	end
	return false
end

return {
	new = new,
}
