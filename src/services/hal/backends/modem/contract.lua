local function list_to_map(list)
    local map = {}
    for _, item in ipairs(list) do
        map[item] = true
    end
    return map
end

local BACKEND_FUNCTIONS = list_to_map {
    -- Grouped reads
    "read_identity",
    "read_ports",
    "read_sim_info",
    "read_network_info",
    "read_signal",
    "read_traffic",

    -- State monitoring
    "start_state_monitor",
    "monitor_state_op",

    -- SIM monitoring
    "start_sim_presence_monitor",
    "wait_for_sim_present_op",
    "wait_for_sim_present",
    "is_sim_present",
    "trigger_sim_presence_check",

    -- Control operations
    "enable",
    "disable",
    "reset",
    "connect",
    "disconnect",
    "inhibit",
    "uninhibit",
    "set_signal_update_interval"
}

local MONITOR_FUNCTIONS = list_to_map {
    "next_event_op",
}

--- Check that a modem monitor provides all required functions and no extras.
---@param monitor ModemMonitor
---@return string error
local function validate_monitor(monitor)
    for func in pairs(MONITOR_FUNCTIONS) do
        if type(monitor[func]) ~= "function" then
            return "Missing required function: " .. func
        end
    end
    for key, value in pairs(monitor) do
        if type(value) == "function" and not MONITOR_FUNCTIONS[key] then
            return "Monitor provides unsupported function: " .. key
        end
    end
    return ""
end

--- Check that a modem backend provides all required functions and no more
---@param backend ModemBackend
---@return string error
local function validate(backend)
    for func, _ in pairs(BACKEND_FUNCTIONS) do
        if type(backend[func]) ~= "function" then
            return "Missing required function: " .. func
        end
    end

    for key, value in pairs(backend) do
        if type(value) == "function" and not BACKEND_FUNCTIONS[key] then
            return "Backend provides unsupported function: " .. key
        end
    end

    return ""
end

return {
    validate = validate,
    validate_monitor = validate_monitor,
}
