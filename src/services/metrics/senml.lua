-- services/metrics/senml.lua
--
-- SenML (Sensor Markup Language) encoder for the metrics service.
-- Converts a nested metric-values table into a flat array of SenML objects
-- ready for JSON encoding and HTTP publication.

--- Encode a single (name, value, time) triple as a SenML record.
---@param topic string
---@param value  number|string|boolean
---@param time   number?  milliseconds since epoch (optional)
---@return SenMLRecord? senml_obj
---@return string? error
local function encode(topic, value, time)
    if type(topic) ~= 'string' or topic == '' then
        return nil, 'topic must be a non-empty string'
    end
    local vtype = type(value)
    if vtype ~= 'number' and vtype ~= 'string' and vtype ~= 'boolean' then
        return nil, 'value must be number, string or boolean, found ' .. vtype
    end

    local obj = { n = topic }

    if vtype == 'number' then
        obj.v = value
    elseif vtype == 'string' then
        obj.vs = value
    elseif vtype == 'boolean' then
        obj.vb = value
    end

    if time and type(time) == 'number' then
        obj.t = time
    end

    return obj, nil
end

--- Recursively encode a nested values table into a flat SenML array.
---
--- Each leaf may be either:
---   {value = v, time = t}  - a metric sample
---   a plain value           - treated as {value = v}
---
--- Tables without both 'value' and 'time' fields are recursed into with the
--- key appended to the topic (dot-separated).  The special key '__value' does
--- not append anything to the topic.
---
---@param base_topic string
---@param values     table
---@param output     table   accumulator array (created automatically on top call)
---@return table? output
---@return string? error
local function encode_r(base_topic, values, output)
    for k, v in pairs(values) do
        local topic = base_topic
        if k ~= '__value' then
            if base_topic == '' then
                topic = k
            else
                topic = topic .. '.' .. k
            end
        end

        if type(v) == 'table' and not (v.value and v.time) then
            local _, err = encode_r(topic, v, output)
            if err then return nil, err end
        else
            if type(v) ~= 'table' then
                v = { value = v }
            end
            local obj, err = encode(topic, v.value, v.time)
            if err then return nil, err end
            table.insert(output, obj)
        end
    end
    return output, nil
end

return {
    encode   = encode,
    encode_r = function(base_topic, values) return encode_r(base_topic, values, {}) end,
}
