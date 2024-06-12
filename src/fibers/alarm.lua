-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

-- Alarms.

local op = require 'fibers.op'
local fiber = require 'fibers.fiber'
local timer = require 'fibers.timer'
local sc = require 'fibers.utils.syscall'

local function days_in_year(y)
    return y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0) and 366 or 365
end

local function to_time(t)
    local new_t = {year = t.year, month=t.month, day=t.day, hour=t.hour, min=t.min, sec=t.sec}
    local time = os.time(new_t) + t.msec/1e3
    local time_t = os.date("*t", time)
    time_t.msec = t.msec
    return time, time_t
end

-- let's define some constants
local periods = {"year", "month", "day", "hour", "min", "sec", "msec"}
local default = {month=1, day=1, hour=0, min=0, sec=0, msec=0}

-- This function validates a table t intended for scheduling an alarm, ensuring
-- only appropriate fields are specified based on the scheduling type.
local function validate_next_table(t)
    local inc_field
    if t.year then
        return nil, "year should not be specified for a relative alarm"
    elseif t.yday then inc_field = "year"
        if t.month or t.wday or t.day then
            return nil, "neither month, weekday or day of month valid for day of year alarm"
        end
    elseif t.month then inc_field = "year"
        if t.wday then
            return nil, "day of week not valid for yearly alarm"
        end
    elseif t.day then inc_field = "month"
        if t.wday then
            return nil, "day of week not valid for monthly alarm"
        end
    elseif t.wday then inc_field = "day"
    elseif t.hour then inc_field = "day"
    elseif t.min then inc_field = "hour"
    elseif t.sec then inc_field = "min"
    elseif t.msec then inc_field = "sec"
    else
        return nil, "a next alarm must specify at least one of yday, month, day, wday, hour, minute, sec or msec"
    end

    return inc_field, nil
end

-- calculates the absolute time until the next occurrence based on a given time
-- structure t and the current epoch.
local function calculate_next(t, epoch)

    -- first let's make sure that the provided struct makes sense
    local inc_field, _ = validate_next_table(t) -- the time table is pre-validated

    -- let's construct the new date table
    local new_t = {}

    local now = os.date("*t", epoch)
    now.msec = (epoch - math.floor(epoch)) * 1e3

    local default_switch = false
    for _, name in ipairs(periods) do
        if not default_switch and t[name] then default_switch = true end
        if (t.wday or t.yday) and name=="hour" then default_switch = true end
        new_t[name] = (not default_switch and now[name]) or t[name] or default[name]
    end

    -- now let's get the struct we need
    local new_time, new_table = to_time(new_t)

    -- wday and yday are weird ones and we need to renormalise
    if t.wday then
        local increment = (t.wday - new_table.wday + 7) % 7
        new_table.day = new_table.day + increment
        new_time, new_table = to_time(new_table)
    elseif t.yday then
        local no_days = days_in_year(new_table.year)
        local increment = (t.yday - new_table.yday + no_days) % no_days
        new_table.day = new_table.day + increment
        new_time, new_table = to_time(new_table)
    end

    if new_time < epoch then
        new_table[inc_field] = new_table[inc_field] + 1
        new_time, new_table = to_time(new_table)
    end

    return new_time, new_table
end


local AlarmHandler = {}
AlarmHandler.__index = AlarmHandler

local function new_alarm_handler()
    local now = sc.realtime()
    return setmetatable(
        {
            realtime = false,
            abs_buffer = {},
            next_buffer = {},
            abs_timer = timer.new(now), -- Task list for absolute time scheduling
        }, AlarmHandler)
end

local installed_alarm_handler = nil

--- Installs the Alarm Handler into the current scheduler.
-- Must be called before any alarm operations are used.
-- @return The installed AlarmHandler instance.
local function install_alarm_handler()
    if not installed_alarm_handler then
        installed_alarm_handler = new_alarm_handler()
        fiber.current_scheduler:add_task_source(installed_alarm_handler)
    end
    return installed_alarm_handler
end

--- Uninstalls the Alarm Handler from the current scheduler.
-- This should be called to clean up when the Alarm Handler is no longer needed.
local function uninstall_alarm_handler()
    if installed_alarm_handler then
        for i, source in ipairs(fiber.current_scheduler.sources) do
            if source == installed_alarm_handler then
                table.remove(fiber.current_scheduler.sources, i)
                break
            end
        end
        installed_alarm_handler = nil
    end
end

function AlarmHandler:schedule_tasks(sched)
    local now = sc.realtime()

    self.abs_timer:advance(now, sched)

    while true do
        local next_time = self.abs_timer:next_entry_time() - now
        if next_time > sched.maxsleep then break end -- an empty timer will return 'inf' here so nil check not needed
        local task = self.abs_timer:pop()
        sched:schedule_after_sleep(next_time, task.obj)
    end
end

function AlarmHandler:block(time_to_start, t, task)
    if time_to_start < fiber.current_scheduler.maxsleep then
        fiber.current_scheduler:schedule_after_sleep(time_to_start, task)
    else
        self.abs_timer:add_absolute(t, task)
    end
end

function AlarmHandler:clock_synced()
    self.realtime = true
    local now = sc.realtime()
    -- Process buffered absolute tasks
    for _, buffered in ipairs(self.abs_buffer) do
        local time_to_start = buffered.t - now
        self:block(time_to_start, buffered.t, buffered.task)
    end
    -- Process next tasks
    for _, buffered in ipairs(self.next_buffer) do
        local next_time = calculate_next(buffered.t, now)
        local time_to_start = next_time - now
        self:block(time_to_start, next_time, buffered.task)
    end
    self.abs_buffer, self.next_buffer = {}, {} -- Clear the buffer
end

function AlarmHandler:clock_desynced()
    self.realtime = false
end

function AlarmHandler:wait_absolute_op(t)
    local time_to_start
    local function try()
        if not self.realtime then return false end
        time_to_start = t - sc.realtime()
        if time_to_start < 0 then return true end
    end
    local function block(suspension, wrap_fn)
        local task = suspension:complete_task(wrap_fn)
        if not self.realtime then table.insert(self.abs_buffer, {t=t, task=task})
            return
        end
        self:block(time_to_start, t, task)
    end
    return op.new_base_op(nil, try, block)
end

function AlarmHandler:wait_next_op(t)
    local function try()
        return false
    end
    local function block(suspension, wrap_fn)
        local task = suspension:complete_task(wrap_fn)
        if not self.realtime then table.insert(self.next_buffer, {t=t, task=task})
            return
        end
        local now = sc.realtime()
        local target, _ = calculate_next(t, now)
        self:block(target-now, target, task)
    end
    return op.new_base_op(nil, try, block)
end

--- Indicates to the Alarm Handler that time synchronisation has been achieved (through NTP or other methods).
-- Until the user calls clock_synced() all alarms will block. When called,
-- `absolute` alarms will return immediately if their time has elapsed, whereas
-- `next` alarms will be scheduled for their next instance
local function clock_synced()
    return assert(installed_alarm_handler):clock_synced()
end

--- Indicates to the Alarm Handler that time synchronisation has been lost.
-- All new alarms will be buffered until real-time is achieved.
local function clock_desynced()
    return assert(installed_alarm_handler):clock_desynced()
end

--- Creates an operation for an absolute alarm.
-- The operation can be performed immediately if in real-time mode,
-- or buffered to be scheduled upon achieving real-time.
-- @param t The absolute time (epoch) for the alarm.
-- @return A BaseOp representing the absolute alarm operation.
local function wait_absolute_op(t)
    return assert(installed_alarm_handler):wait_absolute_op(t)
end

--- Schedules a task to run at an absolute time.
-- Wrapper for `absolute_op` that immediately performs the operation.
-- @param t The absolute time (epoch) for the alarm.
local function wait_absolute(t)
    return wait_absolute_op(t):perform()
end

--- Creates an operation for a next (relative) alarm.
-- The operation is always buffered until real-time is achieved,
-- then scheduled based on the calculated next time.
-- @param t A table specifying the relative time for the alarm.
-- @return A BaseOp representing the next alarm operation.
-- @return An error if the time table is invalid.
local function wait_next_op(t)
    local _, err = validate_next_table(t)
    return err or assert(installed_alarm_handler):wait_next_op(t)
end

--- Schedules a task based on a relative next time.
-- Wrapper for `next_op` that immediately performs the operation.
-- @param t A table specifying the relative time for the alarm.
-- @return An error if the time table is invalid.
local function wait_next(t)
    local _, err = validate_next_table(t)
    return err or assert(installed_alarm_handler):wait_next_op(t):perform()
end

-- Public API
return {
    install_alarm_handler = install_alarm_handler,
    uninstall_alarm_handler = uninstall_alarm_handler,
    clock_synced = clock_synced,
    clock_desynced = clock_desynced,
    wait_absolute_op = wait_absolute_op,
    wait_absolute = wait_absolute,
    wait_next_op = wait_next_op,
    wait_next = wait_next,
    validate_next_table = validate_next_table,
    calculate_next = calculate_next
}