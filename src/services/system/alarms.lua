-- services/system/alarms.lua
--
-- Alarm and AlarmManager for the system service.
-- Ported directly from old-devicecode-lua/src/services/system/alarms.lua.
-- Relies on fibers.alarm and fibers.utils.syscall for wall-clock scheduling.

local op    = require 'fibers.op'
local falarm = require "fibers.alarm"
local sc    = require 'fibers.utils.syscall'

local REPEAT_TYPES = {
    NONE  = "none",
    DAILY = "daily",
}

---@class Alarm
---@field payload any             Any custom data to be held by the alarm
---@field trigger_time table      Table with hour and min fields
---@field repeat_type string      "none" or "daily"
---@field next_trigger number     Monotonic time when this alarm will next trigger
local Alarm = {}
Alarm.__index = Alarm

--- Create a new Alarm from a configuration table.
---@param config table  { time = "HH:MM", repeats = string?, payload = any }
---@return Alarm? alarm
---@return string error
function Alarm.new(config)
    if not config.time then
        return nil, "Alarm needs a time"
    end

    local hour, minute = config.time:match("^(%d+):(%d+)$")
    if not hour or not minute then
        return nil, "Invalid datetime format, expected 'HH:MM'"
    end
    hour, minute = tonumber(hour), tonumber(minute)
    if not hour or not minute or
       hour < 0 or hour > 23 or minute < 0 or minute > 59 then
        return nil, "Invalid datetime format, expected 'HH:MM', 0 <= HH <= 23, 0 <= MM <= 59"
    end

    local repeat_type = REPEAT_TYPES.NONE
    if config.repeats then
        local repeat_upper = string.upper(config.repeats)
        if REPEAT_TYPES[repeat_upper] then
            repeat_type = REPEAT_TYPES[repeat_upper]
        else
            return nil, "Invalid repeat type: " .. config.repeats
        end
    end

    local trigger_time = { hour = hour, min = minute }

    local _, err = falarm.validate_next_table(trigger_time)
    if err then return nil, err end

    return setmetatable({
        payload      = config.payload,
        trigger_time = trigger_time,
        repeat_type  = repeat_type,
    }, Alarm), ""
end

---@return string error
function Alarm:calc_next_trigger()
    self.next_trigger = falarm.calculate_next(self.trigger_time, sc.realtime())
end

---@class AlarmManager
---@field alarms Alarm[]   sorted by next_trigger ascending
---@field is_synced boolean
local AlarmManager = {}
AlarmManager.__index = AlarmManager

---@return AlarmManager
function AlarmManager.new()
    return setmetatable({ alarms = {}, is_synced = false }, AlarmManager)
end

--- Add an alarm (or a config table that describes one) in sorted order.
---@param alarm Alarm|table
---@return string error
function AlarmManager:add(alarm)
    if type(alarm) == "table" and getmetatable(alarm) ~= Alarm then
        local new_alarm, err = Alarm.new(alarm)
        if not new_alarm then return err end
        alarm = new_alarm
    end

    if not alarm or getmetatable(alarm) ~= Alarm then
        return "Invalid alarm object"
    end

    alarm:calc_next_trigger()

    local i = 1
    -- Insert the alarm in the sorted position based on next_trigger
    while i <= #self.alarms and self.alarms[i].next_trigger < alarm.next_trigger do
        i = i + 1
    end
    table.insert(self.alarms, i, alarm)
    return ""
end

--- Remove all alarms.
function AlarmManager:delete_all()
    self.alarms = {}
end

--- Mark the manager as synced, recalculating all trigger times from now.
function AlarmManager:sync()
    if self.is_synced then return end
    self.is_synced = true
    local old = self.alarms
    self:delete_all()
    for _, alarm in ipairs(old) do
        self:add(alarm)
    end
end

--- Mark the manager as desynced (alarms will not fire until re-synced).
function AlarmManager:desync()
    self.is_synced = false
end

--- Return an op that resolves when the next alarm fires, yielding the alarm.
--- If no alarms are pending or the manager is not synced, returns an op that
--- never resolves.
---@return table operation
function AlarmManager:next_alarm_op()
    if #self.alarms == 0 or not self.is_synced then
        return op.never()
    end

    return falarm.wait_absolute_op(self.alarms[1].next_trigger):wrap(function()
        local alarm = table.remove(self.alarms, 1)
        -- Re-queue repeating alarms.
        if alarm.repeat_type ~= REPEAT_TYPES.NONE then
            self:add(alarm)
        end
        return alarm
    end)
end

return {
    Alarm        = Alarm,
    AlarmManager = AlarmManager,
}
