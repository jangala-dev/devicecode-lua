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

    -- Private reads
    "_read_firmware",

    -- State monitoring
    "start_state_monitor",
    "stop_state_monitor_op",
    "stop_state_monitor",
    "monitor_state_op",

    -- SIM monitoring
    "start_sim_presence_monitor",
    "stop_sim_presence_monitor_op",
    "stop_sim_presence_monitor",
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
    "uninhibit_op",
    "shutdown_op",
    "shutdown",
    "terminate",
    "set_signal_update_interval"
}

local RECOVERY_BACKEND_FUNCTIONS = list_to_map {
    "get_device",
    "reset"
}

local MONITOR_FUNCTIONS = list_to_map {
    "next_event_op",
    "shutdown_op",
    "terminate",
}

local function validate_object_has_functions(object, functions)
    for func in pairs(functions) do
        if type(object[func]) ~= "function" then
            return "Missing required function: " .. func
        end
    end
    for key, value in pairs(object) do
        if type(value) == "function" and not functions[key] then
            return "Object provides unsupported function: " .. key
        end
    end
    return ""
end

--- Check that a modem monitor provides all required functions and no extras.
---@param monitor ModemMonitor
---@return string error
local function validate_monitor(monitor)
    return validate_object_has_functions(monitor, MONITOR_FUNCTIONS)
end

--- Check that a modem backend provides all required functions and no more
---@param backend ModemBackend
---@return string error
local function validate(backend)
    return validate_object_has_functions(backend, BACKEND_FUNCTIONS)
end

local function validate_recovery(backend)
    return validate_object_has_functions(backend, RECOVERY_BACKEND_FUNCTIONS)
end

return {
    validate = validate,
    validate_monitor = validate_monitor,
    validate_recovery = validate_recovery
}
