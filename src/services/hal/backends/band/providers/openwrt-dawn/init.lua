local impl = require "services.hal.backends.band.providers.openwrt-dawn.impl"

---Check whether DAWN is installed and its UCI config is accessible.
---@return boolean
local function is_supported()
    local f = io.open('/etc/config/dawn', 'r')
    if f then f:close() return true end
    return false
end

return {
    is_supported = is_supported,
    backend      = impl,
}
