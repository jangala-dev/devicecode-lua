local utils = {}

function utils.parse_monitor(line)
    if line == nil then return nil, nil, 'monitor message is nil' end
    local status, address = line:match("^(.-)(/org%S+)")
    if address then
        return not status:match("-"), address, nil
    else
        return nil, nil, 'line could not be parsed'
    end
end
function utils.parse_modem_monitor(line)
    if line == nil then return nil, "Modem monitor message is nil" end
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


        result.prev_state = states[1]
        -- If there is no next state then we can define the modem as going from state1 to state1
        result.curr_state = states[2] or states[1]
    end

    -- Extract reason if present
    local reason = line:match("Reason: ([%w%s]+)")
    if reason then
        result.reason = reason
    end

    return result, nil
end

function utils.parse_slot_monitor(line)
    for card_status, slot_status in line:gmatch("Card status:%s*(%S+).-Slot status:%s*(%S+)") do
        if card_status == "active" then
            return slot_status, nil
        end
    end

    return nil, 'could not parse (no active slot or invalid string format)'
end
function utils.starts_with(main_string, start_string)
    if main_string == nil or start_string == nil then return false end
    main_string, start_string = main_string:lower(), start_string:lower()
    -- Use string.sub to get the prefix of mainString that is equal in length to startString
    return string.sub(main_string, 1, string.len(start_string)) == start_string
end

local function split_topic(topic)
    local components = {}

    for token in string.gmatch(topic, "[^/]+") do
        table.insert(components, token)
    end

    return components
end

function utils.parse_control_topic(topic)
    local components = split_topic(topic)
    if #components < 6 then return nil, nil, nil, 'control topic does not contain enough components' end

    local instance = tonumber(components[4])
    if type(instance) ~= 'number' then return nil, nil, nil, 'failed to convert instance to a number' end

    -- capability, instance, endpoint
    return components[3], instance, components[6], nil
end

function utils.parse_device_info_topic(topic)
    local components = split_topic(topic)
    if #components < 6 then return nil, nil, nil, 'device info topic does not contain enough components' end

    local instance = tonumber(components[4])
    if type(instance) ~= 'number' then return nil, nil, nil, 'failed to convert instance to a number' end

    return components[3], instance, components[6]
end
return utils
