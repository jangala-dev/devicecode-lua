local file = require "fibers.io.file"

local function file_exists(path)
    local f, _ = file.open(path, 'r')
    if not f then return false end
    f:close()
    return true
end

local function path_has_command(name)
    local path = os.getenv('PATH') or ''
    for dir in path:gmatch('[^:]+') do
        if file_exists(dir .. '/' .. name) then
            return true
        end
    end
    return false
end

local backend = {}

function backend.new(...)
    local impl = require "services.hal.backends.radio.providers.openwrt.impl"
    return impl.new(...)
end

---Check whether OpenWrt UCI and iw are available on this device.
---@return boolean
local function is_supported()
    return file_exists('/etc/openwrt_release') and path_has_command('iw')
end

return {
    is_supported = is_supported,
    backend      = backend,
}
