-- (c) Snabb project
-- (c) Jangala

-- Use of this source code is governed by the XXXXXXXXX license; see COPYING.

--- Scheduler module.
-- Implements the core scheduler for managing tasks.
-- @module fibers.sched

-- Required modules
local sc = require 'fibers.utils.syscall'
local timer = require 'fibers.timer'

-- Constants
local MAX_SLEEP_TIME = 10

local Scheduler = {}
Scheduler.__index = Scheduler

--- Creates a new Scheduler.
-- @function new
-- @return A new Scheduler.
local function new()
    local ret = setmetatable(
        { next = {}, cur = {}, sources = {}, wheel = timer.new(nil), maxsleep = MAX_SLEEP_TIME },
        Scheduler)
    local timer_task_source = { wheel = ret.wheel }
    -- private method for timer_tast_source
    function timer_task_source:schedule_tasks(sched, now)
        self.wheel:advance(now, sched)
    end

    -- private method for timer_tast_source
    function timer_task_source:cancel_all_tasks()
        -- Implement me!
    end

    ret:add_task_source(timer_task_source)
    return ret
end

--- Adds a task source to the scheduler.
-- @param source The source to add.
function Scheduler:add_task_source(source)
    table.insert(self.sources, source)
    if source.wait_for_events then self.event_waiter = source end
end

--- Schedules a task.
-- @param task Task to be scheduled.
function Scheduler:schedule(task)
    table.insert(self.next, task)
end

--- Gets the current time from the timer wheel.
-- @return Current time.
function Scheduler:now()
    return self.wheel.now
end

--- Schedules a task to be run at a specific time.
-- @tparam number t The time to run the task.
-- @tparam function task The task to run.
function Scheduler:schedule_at_time(t, task)
    self.wheel:add_absolute(t, task)
end

--- Schedules a task to be run after a certain delay.
-- @tparam number dt The delay after which to run the task.
-- @tparam function task The task to run.
function Scheduler:schedule_after_sleep(dt, task)
    self.wheel:add_delta(dt, task)
end

--- Schedules tasks from all sources to the scheduler.
-- @tparam number now The current time.
function Scheduler:schedule_tasks_from_sources(now)
    for i = 1, #self.sources do
        self.sources[i]:schedule_tasks(self, now)
    end
end

--- Runs all scheduled tasks in the scheduler.
-- If a specific time is provided, tasks scheduled for that time are run.
-- @tparam number now (optional) The time to run tasks for.
function Scheduler:run(now)
    if now == nil then now = self:now() end
    self:schedule_tasks_from_sources(now)
    self.cur, self.next = self.next, self.cur
    for i = 1, #self.cur do
        local task = self.cur[i]
        self.cur[i] = nil
        task:run()
    end
end

--- Returns the time of the next scheduled task.
-- @treturn number The time of the next task.
function Scheduler:next_wake_time()
    if #self.next > 0 then return self:now() end
    return self.wheel:next_entry_time()
end

--- Waits for the next scheduled event.
function Scheduler:wait_for_events()
    local now, next_time = sc.monotime(), self:next_wake_time()
    local timeout = math.min(self.maxsleep, next_time - now)
    timeout = math.max(timeout, 0)
    if self.event_waiter then
        self.event_waiter:wait_for_events(self, now, timeout)
    else
        sc.floatsleep(timeout)
    end
end

--- Stops the main loop of the Scheduler.
function Scheduler:stop()
    self.done = true
end

--- Runs the main event loop of the scheduler.
-- The scheduler will continue to run tasks and wait for events until stopped.
function Scheduler:main()
    self.done = false
    repeat
        self:wait_for_events()
        self:run(sc.monotime())
    until self.done
end

--- Shuts down the scheduler.
-- Cancels all tasks from all sources and runs remaining tasks.
-- If there are still tasks after 100 attempts, returns false.
-- @treturn boolean Whether the shutdown was successful.
function Scheduler:shutdown()
    for _ = 1, 100 do
        for i = 1, #self.sources do self.sources[i]:cancel_all_tasks(self) end
        if #self.next == 0 then return true end
        self:run()
    end
    return false
end

return {
    new = new
}
