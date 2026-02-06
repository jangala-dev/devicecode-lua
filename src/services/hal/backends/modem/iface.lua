local function list_to_map(list)
    local map = {}
    for _, item in ipairs(list) do
        map[item] = true
    end
    return map
end

local BACKEND_FUNCTIONS = list_to_map {
    -- Getters
    "imei",
    "device",
    "primary_port",
    "at_ports",
    "qmi_ports",
    "gps_ports",
    "net_ports",
    "access_techs",
    "sim",
    "drivers",
    "plugin",
    "model",
    "revision",
    "operator",
    "rx_bytes",
    "tx_bytes",
    "signal",
    "mcc",
    "mnc",
    "gid1",
    "active_band_class",

    -- others
    "enable",
    "disable",
    "reset",
    "connect",
    "disconnect",
    "inhibit",
    "uninhibit",
    "monitor_state_op",
    "wait_for_sim_present_op",
    "wait_for_sim_present",
    "is_sim_present",
    "trigger_sim_presence_check",
}

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
    validate = validate
}
