-- services/metrics/types.lua
--
-- Shared type definitions and constructors for the metrics service.
-- Follows the same pattern as services/hal/types/external.lua.

---@class TypeConstructors
local new = {}

-------------------------------------------------------------------------------
-- BaseTime
-------------------------------------------------------------------------------

---@class BaseTime
---@field synced boolean
---@field real   number  wall-clock seconds at the monotonic base
---@field mono   number  monotonic seconds at the base
local BaseTime = {}
BaseTime.__index = BaseTime

---Create a new BaseTime anchored to the supplied real/monotonic pair.
---@param real   number
---@param mono   number
---@return BaseTime?
---@return string error
function new.BaseTime(real, mono)
    if type(real) ~= 'number' then
        return nil, "real must be a number"
    end
    if type(mono) ~= 'number' then
        return nil, "mono must be a number"
    end
    return setmetatable({
        synced = false,
        real   = real,
        mono   = mono,
    }, BaseTime), ""
end

-------------------------------------------------------------------------------
-- CloudConfig
-------------------------------------------------------------------------------

---@class CloudChannel
---@field id       string
---@field name     string
---@field metadata table<string, string>

---@class CloudConfig
---@field url       string
---@field thing_key string
---@field channels  CloudChannel[]
local CloudConfig = {}
CloudConfig.__index = CloudConfig

---Create a new CloudConfig.
---@param url       string
---@param thing_key string
---@param channels  CloudChannel[]
---@return CloudConfig?
---@return string error
function new.CloudConfig(url, thing_key, channels)
    if type(url) ~= 'string' or url == '' then
        return nil, "url must be a non-empty string"
    end
    if type(thing_key) ~= 'string' or thing_key == '' then
        return nil, "thing_key must be a non-empty string"
    end
    if type(channels) ~= 'table' then
        return nil, "channels must be a table"
    end
    return setmetatable({
        url       = url,
        thing_key = thing_key,
        channels  = channels,
    }, CloudConfig), ""
end

-------------------------------------------------------------------------------
-- MetricSample  (per-endpoint cache entry)
-------------------------------------------------------------------------------

---@class MetricSample
---@field value number|string|boolean
---@field time  number  monotonic seconds when the value was recorded
local MetricSample = {}
MetricSample.__index = MetricSample

---Create a new MetricSample.
---@param value number|string|boolean
---@param time  number
---@return MetricSample?
---@return string error
function new.MetricSample(value, time)
    local vt = type(value)
    if vt ~= 'number' and vt ~= 'string' and vt ~= 'boolean' then
        return nil, "value must be number, string or boolean"
    end
    if type(time) ~= 'number' then
        return nil, "time must be a number"
    end
    return setmetatable({
        value = value,
        time  = time,
    }, MetricSample), ""
end

-------------------------------------------------------------------------------
-- SenMLRecord  (single SenML object ready for JSON encoding)
-------------------------------------------------------------------------------

---@class SenMLRecord
---@field n  string           SenML name
---@field v  number?          numeric value
---@field vs string?          string value
---@field vb boolean?         boolean value
---@field t  number?          time in milliseconds since epoch
local SenMLRecord = {}
SenMLRecord.__index = SenMLRecord

---Create a new SenMLRecord.
---@param name  string
---@param value number|string|boolean
---@param time  number?  milliseconds since epoch
---@return SenMLRecord?
---@return string? error
function new.SenMLRecord(name, value, time)
    if type(name) ~= 'string' or name == '' then
        return nil, "name must be a non-empty string"
    end
    local vt = type(value)
    if vt ~= 'number' and vt ~= 'string' and vt ~= 'boolean' then
        return nil, "value must be number, string or boolean, found " .. vt
    end
    if time ~= nil and type(time) ~= 'number' then
        return nil, "time must be a number"
    end

    local obj = setmetatable({ n = name }, SenMLRecord)
    if vt == 'number' then obj.v = value end
    if vt == 'string' then obj.vs = value end
    if vt == 'boolean' then obj.vb = value end
    if time then obj.t = time end
    return obj, nil
end

-------------------------------------------------------------------------------
-- ServiceState  (the live mutable state table held in metrics.lua)
-------------------------------------------------------------------------------

---@alias PipelineEntry { pipeline: ProcessPipeline, protocol: string }
---@alias PipelineMap   table<string, PipelineEntry>
---@alias MetricStates  table<string, table>
---@alias MetricValues  table<string, table<string, MetricSample>>

---@class ServiceState
---@field conn             Connection?   nil before M.start() is called
---@field name             string?       nil before M.start() is called
---@field http_send_ch     Channel?      nil before M.start() is called
---@field pipelines_map    PipelineMap
---@field metric_states    MetricStates
---@field endpoint_to_pipe table<string, string>
---@field metric_values    MetricValues
---@field publish_period   number?
---@field cloud_url        string?
---@field mainflux_config  table?
---@field cloud_config     CloudConfig?
---@field base_time        BaseTime?     nil before M.start() is called

return {
    new          = new,
    BaseTime     = BaseTime,
    CloudConfig  = CloudConfig,
    MetricSample = MetricSample,
    SenMLRecord  = SenMLRecord,
}
