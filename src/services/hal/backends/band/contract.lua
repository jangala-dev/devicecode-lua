---Band backend contract definition.
---All band backends must implement the functions listed in BAND_BACKEND_FUNCTIONS.

local BAND_BACKEND_FUNCTIONS = {
    'clear',
    'apply',
}

---Validate that a backend table implements all required functions.
---@param backend table
---@return boolean ok
---@return string  err   Empty string on success.
local function validate(backend)
    if type(backend) ~= 'table' then
        return false, "backend must be a table"
    end
    for _, fn_name in ipairs(BAND_BACKEND_FUNCTIONS) do
        if type(backend[fn_name]) ~= 'function' then
            return false, "backend missing required function: " .. fn_name
        end
    end
    return true, ""
end

return {
    BAND_BACKEND_FUNCTIONS = BAND_BACKEND_FUNCTIONS,
    validate               = validate,
}
