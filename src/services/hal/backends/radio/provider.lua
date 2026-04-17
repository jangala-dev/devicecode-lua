---Radio backend provider.
---Iterates registered backends and returns the first supported one.

local contract = require "services.hal.backends.radio.contract"

local BACKENDS = {
    "services.hal.backends.radio.providers.openwrt",
}

---Instantiate a new backend for the named radio from the first supported provider.
---@param name string  UCI radio section name (e.g. "radio0")
---@return table|nil  backend instance
---@return string     err  "" on success
local function new(name)
    for _, path in ipairs(BACKENDS) do
        local ok, provider = pcall(require, path)
        print("radio", path, ok, (ok == false) and provider or nil)
        if ok and provider.is_supported and provider.is_supported() then
            local backend = provider.backend.new(name)
            local valid, verr = contract.validate(backend)
            if valid then
                return backend, ""
            else
                return nil, "backend " .. path .. " failed contract check: " .. verr
            end
        end
    end
    return nil, "no supported radio backend found on this device"
end

return {
    new = new,
}
