local impl = require "services.hal.backends.radio.providers.openwrt.impl"
local file = require "fibers.io.file"

---Check whether OpenWrt UCI is available on this device.
---@return boolean
local function is_supported()
    local f, _ = file.open('/etc/openwrt_release', 'r')
    if f then f:close() return true end
    return false
end

return {
    is_supported = is_supported,
    backend      = impl,
}
