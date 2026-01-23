---@alias DeviceId string|integer
---@alias DeviceType string
---@alias CapabilityType string
---@alias CapabilityId string|integer
---@alias PublishMethod string
---@alias TopicEntry string|integer
---@alias SubTopic TopicEntry[]
---@alias Metadata table<string, any>
---@alias Info table<string, any>

---@class Capability
---@field command_q Queue
---@field control_list string[]
---@field id CapabilityId


---@class DeviceConnectedEvent
---@field connected boolean
---@field type DeviceType
---@field id DeviceId
---@field data Metadata
---@field capabilities Capability[]
local DeviceConnectedEvent = {}
DeviceConnectedEvent.__index = DeviceConnectedEvent

--- Build a new DeviceConnectedEvent
---@param dev_type DeviceType
---@param id_field string
---@param data Metadata
---@param capabilities Capability[]
---@return DeviceConnectedEvent?
---@return string? error
function DeviceConnectedEvent.new(dev_type, id_field, data, capabilities)
    if dev_type == nil then
        return nil, "dev_type must be provided"
    end
    if id_field == nil then
        return nil, "id_field must be provided"
    end
    if data == nil then
        return nil, "data must be provided"
    end
    if data[id_field] == nil then
        return nil, "data must contain the id_field"
    end
    if type(capabilities) ~= "table" then
        return nil, "capabilities must be a table"
    end
    local self = setmetatable({
        connected = true,
        type = dev_type,
        id = id_field,
        data = data,
        capabilities = capabilities
    }, DeviceConnectedEvent)
    return self, nil
end

---@class DeviceDisconnectedEvent
---@field connected boolean
---@field type DeviceType
---@field id DeviceId
---@field data Metadata
local DeviceDisconnectedEvent = {}
DeviceDisconnectedEvent.__index = DeviceDisconnectedEvent

--- Build a new DeviceDisconnectedEvent
---@param dev_type DeviceType
---@param id_field string
---@param data Metadata
---@return DeviceDisconnectedEvent?
---@return string? error
function DeviceDisconnectedEvent.new(dev_type, id_field, data)
    if dev_type == nil then
        return nil, "dev_type must be provided"
    end
    if id_field == nil then
        return nil, "id_field must be provided"
    end
    if data == nil then
        return nil, "data must be provided"
    end
    if data[id_field] == nil then
        return nil, "data must contain the id_field"
    end
    local self = setmetatable({
        connected = false,
        type = dev_type,
        id = id_field,
        data = data
    }, DeviceDisconnectedEvent)
    return self, nil
end

---@alias DeviceConnectionEvent DeviceConnectedEvent|DeviceDisconnectedEvent

---@class DeviceEvent
---@field connected boolean
---@field type DeviceType
---@field index DeviceId
---@field identity any
---@field metadata Metadata
local DeviceEvent = {}
DeviceEvent.__index = DeviceEvent

--- Build a new DeviceEvent
---@param connected boolean
---@param dev_type DeviceType
---@param index DeviceId
---@param identity any
---@param metadata Metadata
---@return DeviceEvent?
---@return string? error
function DeviceEvent.new(connected, dev_type, index, identity, metadata)
    if type(connected) ~= "boolean" then
        return nil, "connected must be a boolean"
    end
    if dev_type == nil then
        return nil, "dev_type must be provided"
    end
    if index == nil then
        return nil, "index must be provided"
    end
    if identity == nil then
        return nil, "identity must be provided"
    end
    if metadata == nil then
        return nil, "metadata must be provided"
    end
    local self = setmetatable({
        connected = connected,
        type = dev_type,
        index = index,
        identity = identity,
        metadata = metadata
    }, DeviceEvent)
    return self, nil
end

---@class CapabilityDevice
---@field type DeviceType
---@field id DeviceId

---@class CapabilityEvent
---@field connected boolean
---@field type CapabilityType
---@field index CapabilityId
---@field device CapabilityDevice
local CapabilityEvent = {}
CapabilityEvent.__index = CapabilityEvent

--- Build a new CapabilityEvent
---@param connected boolean
---@param cap_type CapabilityType
---@param index CapabilityId
---@param dev_type DeviceType
---@param device_id DeviceId
---@return CapabilityEvent?
---@return string? error
function CapabilityEvent.new(connected, cap_type, index, dev_type, device_id)
    if type(connected) ~= "boolean" then
        return nil, "connected must be a boolean"
    end
    if cap_type == nil then
        return nil, "cap_type must be provided"
    end
    if index == nil then
        return nil, "index must be provided"
    end
    if dev_type == nil then
        return nil, "dev_type must be provided"
    end
    if device_id == nil then
        return nil, "device_id must be provided"
    end
    local self = setmetatable({
        connected = connected,
        type = cap_type,
        index = index,
        device = { type = dev_type, id = device_id }
    }, CapabilityEvent)
    return self, nil
end

---@class InfoEvent
---@field type CapabilityType
---@field index CapabilityId
---@field sub_topic SubTopic
---@field publish_method PublishMethod
---@field info Info
local InfoEvent = {}
InfoEvent.__index = InfoEvent

--- Build a new InfoEvent
---@param cap_type CapabilityType
---@param index CapabilityId
---@param sub_topic SubTopic
---@param publish_method PublishMethod
---@param info Info
---@return InfoEvent?
---@return string? error
function InfoEvent.new(cap_type, index, sub_topic, publish_method, info)
    if cap_type == nil then
        return nil, "cap_type must be provided"
    end
    if index == nil then
        return nil, "index must be provided"
    end
    if type(sub_topic) ~= "table" then
        return nil, "sub_topic must be a table"
    end
    if publish_method == nil then
        return nil, "publish_method must be provided"
    end
    local self = setmetatable({
        type = cap_type,
        index = index,
        sub_topic = sub_topic,
        publish_method = publish_method,
        info = info
    }, InfoEvent)
    return self, nil
end

---@class Reply
---@field result any
---@field error any
local Reply = {}
Reply.__index = Reply

--- Build a new Reply
---@param result any
---@param error any
---@return Reply
function Reply.new(result, error)
    return setmetatable({
        result = result,
        error = error
    }, Reply)
end

return {
    DeviceConnectedEvent = DeviceConnectedEvent,
    DeviceDisconnectedEvent = DeviceDisconnectedEvent,
    DeviceEvent = DeviceEvent,
    CapabilityEvent = CapabilityEvent,
    InfoEvent = InfoEvent,
    Reply = Reply
}
