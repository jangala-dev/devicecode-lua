---Radio backend contract definition.
---All radio backends must implement the functions listed in RADIO_BACKEND_FUNCTIONS.

local RADIO_BACKEND_FUNCTIONS = {
    'get_meta',
    'apply',
    'clear',
    'start_client_monitor',
    'watch_clients_op',
    'get_connected_macs',
    'get_iface_info',
    'get_iface_survey',
    'get_station_info',
}

---Validate that a backend table implements all required functions.
---@param backend table
---@return boolean ok
---@return string  err   Empty string on success.
local function validate(backend)
    if type(backend) ~= 'table' then
        return false, "backend must be a table"
    end
    for _, fn_name in ipairs(RADIO_BACKEND_FUNCTIONS) do
        if type(backend[fn_name]) ~= 'function' then
            return false, "backend missing required function: " .. fn_name
        end
    end
    return true, ""
end

return {
    RADIO_BACKEND_FUNCTIONS = RADIO_BACKEND_FUNCTIONS,
    validate                = validate,
}
