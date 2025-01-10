local utils = {}

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

function utils.starts_with(main_string, start_string)
    if main_string == nil or start_string == nil then return false end
    main_string, start_string = main_string:lower(), start_string:lower()
    -- Use string.sub to get the prefix of mainString that is equal in length to startString
    return string.sub(main_string, 1, string.len(start_string)) == start_string
end

return utils
