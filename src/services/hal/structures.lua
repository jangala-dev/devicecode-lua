---@alias event_key [string, number]
---@class EventList A list of get operations
---@field events BaseOp[]
---@field event_ids event_key[]
local EventList = {}
EventList.__index = EventList
---Creates an empty EventList
---@return EventList
function EventList.new()
    local self = setmetatable({}, EventList)
    self.events = {}
    self.event_ids = {}
    return self
end

---Adds an operation to the event list
---@param event_id event_key
---@param event_op BaseOp
function EventList:add(event_id, event_op)
    -- add event to events list
    table.insert(self.events, event_op)
    table.insert(self.event_ids, event_id)
end

---removes an operation from the event list
---@param event_id event_key
function EventList:remove(event_id)
    local i = 1
    while i <= #self.events do
        if self.event_ids[i][1] == event_id[1] and self.event_ids[i][2] == event_id[2] then
            table.remove(self.events, i)
            table.remove(self.event_ids, i)
        else
            i = i + 1
        end
    end
end

---get all operations
---@return BaseOp[]
function EventList:get_events()
    return self.events
end

Tracker = {}
Tracker.__index = Tracker

function Tracker.new()
    local self = setmetatable({}, Tracker)
    self.current_idx = 1
    self.devices = {}
    return self
end

function Tracker:get(index)
    return self.devices[index]
end

function Tracker:add(device)
    local dev_idx = self.current_idx
    self.devices[dev_idx] = device
    self.current_idx = self.current_idx + 1
    return dev_idx
end

function Tracker:next_index()
    return self.current_idx
end
function Tracker:remove(index)
    if self.devices[index] ~= nil then
        self.devices[index] = nil
        return true
    end
    return false
end

return {
    new_event_list = EventList.new,
    new_tracker = Tracker.new,
}
