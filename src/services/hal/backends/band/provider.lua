---Band backend provider.
---Iterates registered backends and returns the first supported one.

local contract = require "services.hal.backends.band.contract"

local BACKENDS = {
    "services.hal.backends.band.providers.openwrt-dawn",
}

---Get the first supported band backend.
---@return table|nil  backend
---@return string     err  "" on success
local function get_backend()
    for _, path in ipairs(BACKENDS) do
        local ok, provider = pcall(require, path)
        if ok and provider.is_supported and provider.is_supported() then
            local backend = provider.backend
            local valid, verr = contract.validate(backend)
            if valid then
                return backend, ""
            else
                return nil, "backend " .. path .. " failed contract check: " .. verr
            end
        end
    end
    return nil, "no supported band backend found on this device"
end

return {
    get_backend = get_backend,
}
