local utils = {}

function utils.parse_monitor(line)
    local status, address = line:match("^(.-)(/org%S+)")
    if address then
        return not status:match("-"), address, nil
    else
        return nil, nil, 'line could not be parsed'
    end
end

function utils.parse_address_index(address)
    local index = address:match(".*/(%d+)$")

    if index then return index, nil end
    return nil, 'index could not be found'
end

function utils.parse_modem_monitor(line)
    local result = {}

    -- Detect type of the line
    if line:match("Initial state") then
        result.type = "initial"
    elseif line:match("State changed") then
        result.type = "changed"
    elseif line:match("Removed") then
        result.type = "removed"
    else
        return nil, "Unknown modem monitor message: "..line
    end

    -- Extract state
    if result.type == "initial" or result.type == "changed" then
        local states = {}
        for state in line:gmatch("'(%w+)'") do
            table.insert(states, state)
        end
        -- result.current_state = states[#states] -- get the last state
        result.prev_state = states[1]
        result.curr_state = states[2]
    end

    -- Extract reason if present
    local reason = line:match("Reason: ([%w%s]+)")
    if reason then
        result.reason = reason
    end

    return result, nil
end

function utils.parse_control_topic(topic)
    local components = {}

    for token in string.gmatch(topic, "[^/]+") do
        table.insert(components, token)
    end

    if #components < 6 then return nil, nil, nil, 'control topic does not contain enough components' end

    return components[3], components[4], components[6], nil
end

function utils.make_cap_message(name, index, connected)
    return {
        topic = string.format('hal/capability/%s/%s', name, index),
        payload = {
            connected = connected,
            name = name,
            index = index
        },
        retained = true
    }
end

function utils.make_device_message(type, index, identity, connected)
    return {
        topic = string.format('hal/device/%s/%s', type, index),
        payload = {
            status = {
                connected = connected,
                time = nil
            },
            identity = identity,
            type = type,
            index = index
        },
        retained = true
    }
end

function utils.make_request_reply(reply_to, result, error)
    return {
        topic = reply_to,
        payload = {
            result = result,
            error = error
        }
    }
end


return utils