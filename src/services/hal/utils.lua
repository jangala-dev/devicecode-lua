local file = require "fibers.stream.file"

local utils = {}

---@param path string
---@return string?
---@return string? Error
function utils.read_file(path)
    local file, err = file.open(path, "r")
    if err then return nil, err end
    local content = file:read_all_chars()

    file:close()
    return content, nil
end

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
        if slot_status == "active" then
            return card_status, nil
        end
    end

    return line, 'could not parse (no active slot or invalid string format)'
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
--- qmicli output is nasty so convert it to a lua table and remap ugly keys
--- it does not handle qmicli lists as of yet
---@param output string the output of a qmicli command
---@param key_map { string: string }? a mapping of qmicli key names against custom key names
---@return table? qmicli output as a lua table
---@return string? error
function utils.parse_qmicli_output(output, key_map)
    if output == nil then return nil, "Output is nil" end
    key_map = key_map or {}

    local function clean_key(key)
        return key_map[key] or key
    end

    local result = {}
    local current_table = result
    local table_stack = {}
    local indent_stack = { 0 }
    local line_num = 0

    for line in output:gmatch("[^\r\n]+") do
        local indent = line:match("^%s*"):len()
        local cleaned_line = line:match("^%s*(.-)%s*$")
        if line_num == 0 then goto continue end
        if line:match("^%s*$") then goto continue end

        -- Find the appropriate parent table based on indentation
        while #indent_stack > 1 and indent <= indent_stack[#indent_stack] do
            table.remove(indent_stack)
            table.remove(table_stack)
            current_table = #table_stack > 0 and table_stack[#table_stack] or result
        end

        if cleaned_line:match(":$") then
            local section = cleaned_line:match("^(.+):$")
            section = clean_key(section)
            current_table[section] = {}
            table.insert(table_stack, current_table[section])
            table.insert(indent_stack, indent)
            current_table = current_table[section]
        else
            local key, value = cleaned_line:match("^([^:]+):%s*(.+)$")
            if key and value then
                key = clean_key(key:match("^%s*(.-)%s*$"))
                value = value:match("^%s*(.-)%s*$")

                local num_value = tonumber(value)
                if num_value then
                    value = num_value
                elseif value == "yes" then
                    value = true
                elseif value == "no" then
                    value = false
                else
                    -- remove any quotation marks
                    value = value:match("^'?(.-)'?$")
                end

                current_table[key] = value
            end
        end

        ::continue::
        line_num = line_num + 1
    end

    return result, nil
end

function utils.is_in(item, list, key)
    if key == nil then key = function(x) return x end end
    for _, v in ipairs(list) do
        if key(v) == item then
            return true
        end
    end
    return false
end

return utils
