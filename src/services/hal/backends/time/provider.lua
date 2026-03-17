---Time backend provider factory.
---Selects the appropriate TimeBackend implementation based on the runtime platform.

local contract = require "services.hal.backends.time.contract"

local BACKENDS = {
    "openwrt"
}

--- Select and initialize the backend implementation
---@return table backend_impl
local function get_backend_impl()
    local backend_impl = nil
    for _, backend_name in ipairs(BACKENDS) do
        local ok, backend_mod = pcall(require, "services.hal.backends.time.providers." .. backend_name .. ".init")
        if ok and type(backend_mod) == "table" and backend_mod.is_supported and backend_mod.is_supported() then
            backend_impl = backend_mod.backend
            break
        end
    end

    if backend_impl == nil then
        error("No supported time backend found")
    end

    return backend_impl
end

---Create a new TimeBackend instance.
---
---Detects the platform and instantiates the appropriate backend implementation.
---Fails with an error if no supported backend is found.
---
---@return TimeBackend
local function new()
    local backend_impl = get_backend_impl()
    local backend = backend_impl.new()

    local iface_err = contract.validate(backend)
    if iface_err ~= "" then
        error("Time backend does not implement required interface: " .. tostring(iface_err))
    end

    return backend
end

return {
    new = new,
}
