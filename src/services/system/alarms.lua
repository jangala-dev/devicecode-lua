local op = require 'fibers.op'
local falarm = require "fibers.alarm"
local sc = require 'fibers.utils.syscall'

falarm.install_alarm_handler()
falarm.clock_synced()

local REPEAT_TYPES = {
    NONE = "none",
    DAILY = "daily",
    -- WEEKLY = "weekly",
    -- MONTHLY = "monthly"
}

---@class Alarm
---@field payload any Any custom data to be held by the alarm
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
    if not config.time then
        return nil, "Alarm needs a time"
    end

    local hour, minute
    if config.time then
        -- Parse datetime (expected format: "HH:MM")
        hour, minute = config.time:match("^(%d+):(%d+)$")
        if not hour or not minute then
            return nil, "Invalid datetime format, expected 'HH:MM'"
        end
        hour, minute = tonumber(hour), tonumber(minute)
        if not hour or not minute or hour < 0 or hour > 23 or minute < 0 or minute > 59 then
            return nil, "Invalid datetime format, expected 'HH:MM', 0 < HH < 23, 0 < MM < 59"
        end
    else
        hour, minute = 0, 0
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
        min = minute
    }

    local _, err = falarm.validate_next_table(trigger_time)
    if err then return nil, err end

    local time_trigger, _ = falarm.calculate_next(trigger_time, sc.realtime())

    -- Create the alarm with parsed values
    local alarm = setmetatable({
        payload = config.payload,
        trigger_time = trigger_time,
        repeat_type = repeat_type,
        next_trigger = time_trigger
    }, Alarm)
    return alarm
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
function AlarmManager:delete_all()
    self.next_alarm = nil
end

--- Create an operation that waits until the next alarm triggers.
---@return table operation Operation that resolves when the next alarm triggers
function AlarmManager:next_alarm_op()
    if not self.next_alarm then
        -- No alarms, create an operation that will never complete
        return op.new_base_op(
            nil,
            function() return false end,
            function() end
        )
    end

    -- Create an operation that will sleep until the next alarm triggers
    return falarm.wait_absolute_op(self.next_alarm.alarm.next_trigger):wrap(function()
        local alarm = self.next_alarm.alarm
        self.next_alarm = self.next_alarm.next_alarm
        -- Recalculate the next trigger time for repeating alarms
        if alarm.repeat_type ~= REPEAT_TYPES.NONE then
            alarm.next_trigger = falarm.calculate_next(alarm.trigger_time, sc.realtime())
            self:add(alarm)
        end

        -- Return the alarm that triggered
        return alarm
    end)
end

return {
    Alarm = Alarm,
    AlarmManager = AlarmManager,
}
