local sleep = require 'fibers.sleep'
local op = require 'fibers.op'
local syscall = require 'fibers.utils.syscall'

local ALARM_TYPES = {
    SHUTDOWN = "shutdown",
    REBOOT = "reboot"
}

local REPEAT_TYPES = {
    NONE = "none",
    DAILY = "daily",
    WEEKLY = "weekly",
    MONTHLY = "monthly"
}

---@class Alarm
---@field name string The name of the alarm
---@field type string The type of the alarm (shutdown or reboot)
---@field trigger_time table Table with hour and minute fields
---@field repeat_type string The repeat type (none, daily, weekly, monthly)
---@field next_trigger number The monotonic time when this alarm will next trigger
local Alarm = {}
Alarm.__index = Alarm

--- Create a new alarm from either parameters or a configuration table.
---@param config table Either the name of the alarm or a configuration table
---@return Alarm? alarm A new alarm instance or nil if error
---@return string? error Error message if validation fails
function Alarm.new(config)
    -- Validate required fields
    if not config.name then
        return nil, "Missing name in alarm configuration"
    end

    if not config.action then
        return nil, "Missing action in alarm configuration"
    end

    if not config.datetime then
        return nil, "Missing datetime in alarm configuration"
    end

    -- Parse action to alarm type
    local alarm_type
    if config.action == "reboot" then
        alarm_type = ALARM_TYPES.REBOOT
    elseif config.action == "shutdown" then
        alarm_type = ALARM_TYPES.SHUTDOWN
    else
        return nil, "Invalid action: " .. config.action
    end

    -- Parse datetime (expected format: "HH:MM")
    local hour, minute = config.datetime:match("^(%d+):(%d+)$")
    hour, minute = tonumber(hour), tonumber(minute)

    if not hour or not minute or hour < 0 or hour > 23 or minute < 0 or minute > 59 then
        return nil, "Invalid datetime format, expected 'HH:MM'"
    end

    -- Parse repeat type
    local repeat_type = REPEAT_TYPES.NONE
    if config.repeats then
        local repeat_upper = string.upper(config.repeats)
        if REPEAT_TYPES[repeat_upper] then
            repeat_type = REPEAT_TYPES[repeat_upper]
        else
            return nil, "Invalid repeat type: " .. config.repeats
        end
    end

    -- Create trigger_time table
    local trigger_time = {
        hour = hour,
        minute = minute
    }

    -- For weekly alarms, allow specifying weekday
    if repeat_type == REPEAT_TYPES.WEEKLY and config.weekday then
        local weekday = tonumber(config.weekday)
        if weekday and weekday >= 1 and weekday <= 7 then
            trigger_time.wday = weekday
        else
            return nil, "Invalid weekday, expected 1-7"
        end
    end

    -- For monthly alarms, allow specifying day of month
    if repeat_type == REPEAT_TYPES.MONTHLY and config.day then
        local day = tonumber(config.day)
        if day and day >= 1 and day <= 31 then
            trigger_time.day = day
        else
            return nil, "Invalid day of month, expected 1-31"
        end
    end

    -- Create the alarm with parsed values
    local alarm = setmetatable({
        name = config.name,
        type = alarm_type,
        trigger_time = trigger_time,
        repeat_type = repeat_type,
        next_trigger = 0  -- Manager will set this later
    }, Alarm)
    return alarm
end

--- Compare two times for which is further in the future.
--- @param time1 number[] First time to compare
--- @param time2 number[] Second time to compare
--- @return integer 0 if equal, 1 if time1 > time2, 2 if time2 > time1
--- @return string? Error
local function time_compare(time1, time2)
    if #time1 ~= #time2 then return 0, 'Both times must have the same number of parts' end
    for i, part in ipairs(time1) do
        if part < time2[i] then
            return 2
        elseif part > time2[i] then
            return 1
        end
    end
    return 0, nil
end

--- Calculate when this alarm will next trigger based on current time
---@return number time The monotonic time when this alarm will next trigger
function Alarm:calculate_next_trigger()
    -- Get current wall clock time
    local walltime = os.date("*t")
    local now = {
        minute = walltime.min,
        hour = walltime.hour,
        day = walltime.day,
        wday = walltime.wday,
        month = walltime.month,
        year = walltime.year
    }

    local target = {
        minute = self.trigger_time.minute,
        hour = self.trigger_time.hour,
        day = walltime.day,
        wday = self.trigger_time.wday or now.wday,
        month = walltime.month,
        year = walltime.year
    }

    -- Determine when the alarm should next trigger
    if self.repeat_type == REPEAT_TYPES.DAILY then
        -- If trigger time is earlier today, set for tomorrow
        if time_compare({target.hour, target.minute}, {now.hour, now.minute}) ~= 1 then
            target.day = target.day + 1
        end
    elseif self.repeat_type == REPEAT_TYPES.WEEKLY then
        -- Calculate days until the next occurrence of that day of week
        local days_ahead = (target.wday - now.wday) % 7
        -- If it's today but the time has passed, add 7 days
        if time_compare({target.wday, target.hour, target.minute}, {now.wday, now.hour, now.minute}) ~= 1 then
            days_ahead = 7
        end
        target.day = now.day + days_ahead
    elseif self.repeat_type == REPEAT_TYPES.MONTHLY then
        -- Store the day of month from the original trigger time
        local target_day = self.trigger_time.day or now.day
        -- If today is that day but time has passed, or if that day is already past this month
        if time_compare({target.day, target.hour, target.minute}, {now.day, now.hour, now.minute}) ~= 1 then
            -- Move to next month
            target.month = target.month + 1
            if target.month > 12 then
                target.month = 1
                target.year = target.year + 1
            end
        end
        -- Set the target day
        target.day = target_day
    else
        -- Non-repeating alarm
        -- If trigger time has passed today, it'll never trigger again
        if target.hour < now.hour or (target.hour == now.hour and target.minute <= now.minute) then
            return math.huge -- Never trigger
        end
    end

    -- Convert the target time to seconds since epoch
    local target_time = os.time({
        year = target.year,
        month = target.month,
        day = target.day,
        hour = target.hour,
        min = target.minute,
        sec = 0
    })

    -- Convert from realtime to monotime for fibers compatibility
    local monotime_now = syscall.monotime()
    local realtime_now = os.time()

    local time_diff = target_time - realtime_now
    return monotime_now + time_diff
end

---@class AlarmManager
local AlarmManager = {}
AlarmManager.__index = AlarmManager

--- Create a new AlarmManager.
---@return AlarmManager manager A new AlarmManager instance
function AlarmManager.new()
    return setmetatable({
        next_alarm = nil
    }, AlarmManager)
end

--- Add an alarm to the manager.
---@param alarm Alarm|table The alarm to add or a config of an alarm
---@return string? error Error message if alarm is invalid
function AlarmManager:add(alarm)
    -- If alarm is a config table, create an Alarm instance
    if type(alarm) == "table" and getmetatable(alarm) ~= Alarm then
        local new_alarm, err = Alarm.new(alarm)
        if not new_alarm then
            return err
        end
        alarm = new_alarm
    end

    -- Validate alarm
    if not alarm or getmetatable(alarm) ~= Alarm then
        return "Invalid alarm object"
    end

    -- Calculate when this alarm will next trigger
    alarm.next_trigger = alarm:calculate_next_trigger()

    if self.next_alarm then
        local prev = self.next_alarm
        local head = self.next_alarm
        while head and head.alarm.next_trigger < alarm.next_trigger do
            prev = head
            head = head.next_alarm
        end
        if head == self.next_alarm then
            self.next_alarm = {alarm = alarm, next_alarm = head}
        else
            prev.next_alarm = { alarm = alarm, next_alarm = head }
        end
    else
        self.next_alarm = { alarm = alarm, next_alarm = nil }
    end
end

--- Delete all alarms from the manager.
---@return AlarmManager manager The AlarmManager instance for chaining
function AlarmManager:delete_all()
    self.next_alarm = nil
end

--- Create an operation that waits until the next alarm triggers.
---@return table operation Operation that resolves when the next alarm triggers
function AlarmManager:next_alarm_op()
    if not self.next_alarm then
        -- No alarms, create an operation that will never complete
        return op.new_base_op(
            function()
                return {
                    alarm = nil,
                    type = nil,
                    name = nil
                }
            end,
            function() return false end,
            function() end
        )
    end

    -- Create an operation that will sleep until the next alarm triggers
    return sleep.sleep_until_op(self.next_alarm.alarm.next_trigger):wrap(function()
        local alarm = self.next_alarm.alarm
        self.next_alarm = self.next_alarm.next_alarm
        -- Recalculate the next trigger time for repeating alarms
        if alarm.repeat_type ~= REPEAT_TYPES.NONE then
            self:add(alarm)
        end

        -- Return information about the alarm that triggered
        return alarm
    end)
end

return {
    ALARM_TYPES = ALARM_TYPES,
    REPEAT_TYPES = REPEAT_TYPES,
    Alarm = Alarm,
    AlarmManager = AlarmManager,
}
