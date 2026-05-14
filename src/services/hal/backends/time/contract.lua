---@class TimeBackend
---@field start_ntp_monitor fun(self: TimeBackend): boolean, string
---@field ntp_event_op fun(self: TimeBackend): Op
---@field stop fun(self: TimeBackend): boolean, string

local BACKEND_FUNCTIONS = {
    "start_ntp_monitor",
    "ntp_event_op",
    "stop",
}

---Check that a time backend provides all required functions.
---@param backend TimeBackend
---@return string error Empty string on success.
local function validate(backend)
    for _, func in ipairs(BACKEND_FUNCTIONS) do
        if type(backend[func]) ~= "function" then
            return "Missing required function: " .. func
        end
    end
    return ""
end

return {
    validate = validate
}
