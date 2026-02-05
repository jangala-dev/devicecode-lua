local iface = require "services.hal.backends.modem.iface"

local backends = {
    "linux_mm"
}

local backend = nil
for _, backend_name in ipairs(backends) do
    local ok, mod = pcall(require, "services.hal.backends.modem.providers." .. backend_name .. ".init")
    if ok and type(mod.is_supported) == "function" and mod.is_supported() then
        backend = mod
        break
    end
end

if backend == nil then
    error("No supported modem backend found")
end

--- Apply mode specific functions
---@param mode string
---@return boolean ok
function backend:override_mode(mode)
    local ok, mod = pcall(require, "services.hal.backends.modem.modes." .. mode)
    if ok and type(mod) == "function" then
        mod(self)
        return true
    end
    return false
end

--- Apply model specific functions
---@param manufacturer string
---@param model string
---@param variant string
---@return boolean ok
function backend:override_model(manufacturer, model, variant)
    local ok, mod = pcall(require, "services.hal.backends.modem.models." .. manufacturer)
    if ok and type(mod) == "function" then
        mod(self, model, variant)
        return true
    end
    return false
end

--- Check that all required backend functions are implemented
---@return boolean ok
---@return string? error
function backend:validate()
    return iface.validate_backend(self)
end

return backend
