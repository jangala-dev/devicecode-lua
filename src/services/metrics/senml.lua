local function encode(topic, value, time)
    local vtype = type(value)
    if vtype ~= 'number' and vtype ~= 'string' and vtype ~= "boolean" then
         return nil, "value must be number, string or boolean, found " .. vtype
    end

    local senml_obj = {n = topic}

    if vtype == 'string' then senml_obj.vs = value
    elseif vtype == 'number' then senml_obj.v = value
    elseif vtype == 'boolean' then senml_obj.vb = value
    end

    if time and type(time) == 'number' then
        senml_obj.t = time
    end
    return senml_obj
end

local function encode_r(base_topic, values, output)
    for k, v in pairs(values) do
        local topic = base_topic
        if k ~= '__value' then
            if base_topic == ''  then
                topic = k
            else
                topic = topic .. "." .. k
            end
        end

        if type(v) == 'table' then
            local _, err = encode_r(topic, v, output)
            if err then return nil, err end
        else
            local senml_obj, err = encode(topic, v)
            if err then return nil, err end
            table.insert(output, senml_obj)
        end
    end
    return output, nil
end

return {
    encode = encode,
    encode_r = function(base_topic, values) return encode_r(base_topic, values, {}) end
}
