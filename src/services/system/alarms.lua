-- services/system/alarms.lua
--
-- Alarm and AlarmManager for the system service.
-- Adapted to the current fibers.alarm API for wall-clock scheduling.

local op     = require 'fibers.op'
local falarm = require "fibers.alarm"

local REPEAT_TYPES = {
    NONE  = "none",
    DAILY = "daily",
}

local time_source_ready = false

local function ensure_time_source()
    if time_source_ready then
        return
    end

    local ok, err = pcall(falarm.set_time_source, os.time)
    if not ok and not tostring(err):match("set_time_source may only be called once") then
        error(err)
    end

    time_source_ready = true
end

---@class AlarmTriggerTime
---@field hour integer
---@field min integer

---@param trigger_time AlarmTriggerTime
---@param repeat_type string
---@param last number?
---@param now number
---@return number?
local function next_local_trigger(trigger_time, repeat_type, last, now)
    local t

    if last ~= nil then
        if repeat_type == REPEAT_TYPES.NONE then
            return nil
        end

        t = os.date('*t', last)
        t.day = t.day + 1
    else
        t = os.date('*t', now)
        local past = t.hour > trigger_time.hour
            or (t.hour == trigger_time.hour and t.min >= trigger_time.min)
        if past then
            t.day = t.day + 1
        end
    end

    ---@cast t osdate
    t.hour, t.min, t.sec = trigger_time.hour, trigger_time.min, 0
    return os.time(t)
end

---@param trigger_time AlarmTriggerTime
---@param repeat_type string
---@return Alarm
local function build_wait_alarm(trigger_time, repeat_type)
    ensure_time_source()
    return falarm.new {
        next_time = function(last, now)
            return next_local_trigger(trigger_time, repeat_type, last, now)
        end,
        label = string.format('system_%s_%02d:%02d', repeat_type, trigger_time.hour, trigger_time.min),
    }
end

---@class AlarmConfig
---@field time string
---@field repeats string?
---@field payload any

---@class SystemAlarm
---@field payload any                 Any custom data to be held by the alarm
---@field trigger_time AlarmTriggerTime
---@field repeat_type string          "none" or "daily"
---@field next_trigger number         Next wall-clock trigger epoch
---@field wait_alarm Alarm
local Alarm = {}
Alarm.__index = Alarm

--- Create a new Alarm from a configuration table.
---@param config AlarmConfig
---@return SystemAlarm? alarm
---@return string error
function Alarm.new(config)
    if type(config) ~= 'table' then
        return nil, "Alarm config must be a table"
    end

    if type(config.time) ~= 'string' or config.time == '' then
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
    if config.repeats ~= nil then
        if type(config.repeats) ~= 'string' then
            return nil, "Invalid repeat type"
        end
        local repeat_upper = string.upper(config.repeats)
        if REPEAT_TYPES[repeat_upper] then
            repeat_type = REPEAT_TYPES[repeat_upper]
        else
            return nil, "Invalid repeat type: " .. config.repeats
        end
    end

    local trigger_time = { hour = hour, min = minute }

    local next_trigger = next_local_trigger(trigger_time, repeat_type, nil, os.time())
    if not next_trigger then
        return nil, "Failed to calculate next trigger"
    end

    return setmetatable({
        payload      = config.payload,
        trigger_time = trigger_time,
        repeat_type  = repeat_type,
        next_trigger = next_trigger,
        wait_alarm   = build_wait_alarm(trigger_time, repeat_type),
    }, Alarm), ""
end

---@return string error
function Alarm:calc_next_trigger()
    local next_trigger = next_local_trigger(self.trigger_time, self.repeat_type, nil, os.time())
    if not next_trigger then
        return "Failed to calculate next trigger"
    end

    self.next_trigger = next_trigger
    self.wait_alarm = build_wait_alarm(self.trigger_time, self.repeat_type)
    return ""
end

---@class SystemAlarmManager
---@field alarms SystemAlarm[]   sorted by next_trigger ascending
---@field is_synced boolean
local AlarmManager = {}
AlarmManager.__index = AlarmManager

---@return SystemAlarmManager
function AlarmManager.new()
    return setmetatable({ alarms = {}, is_synced = false }, AlarmManager)
end

--- Add an alarm (or a config table that describes one) in sorted order.
---@param alarm SystemAlarm|AlarmConfig
---@return string error
function AlarmManager:add(alarm)
    if type(alarm) == "table" and getmetatable(alarm) ~= Alarm then
        ---@cast alarm AlarmConfig
        local new_alarm, err = Alarm.new(alarm)
        if not new_alarm then return err end
        alarm = new_alarm
    end

    if not alarm or getmetatable(alarm) ~= Alarm then
        return "Invalid alarm object"
    end

    local calc_err = alarm:calc_next_trigger()
    if calc_err ~= "" then
        return calc_err
    end

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
---@return Op operation
function AlarmManager:next_alarm_op()
    if #self.alarms == 0 or not self.is_synced then
        return op.never()
    end

    local head = self.alarms[1]
    return head.wait_alarm:wait_op():wrap(function()
        local alarm = table.remove(self.alarms, 1)
        -- Re-queue repeating alarms.
        if alarm.repeat_type ~= REPEAT_TYPES.NONE then
            local add_err = self:add(alarm)
            if add_err ~= "" then
                error("Failed to re-add repeating alarm: " .. add_err)
            end
        end
        return alarm
    end)
end

return {
    Alarm        = Alarm,
    AlarmManager = AlarmManager,
}
