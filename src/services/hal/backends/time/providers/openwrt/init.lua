local file = require "fibers.io.file"
local exec = require "fibers.io.exec"
local fibers = require "fibers"

local backend = require "services.hal.backends.time.providers.openwrt.impl"

local function is_linux()
    local fh, open_err = file.open("/proc/version", "r")
    if not fh or open_err then
        return false
    end

    local content, read_err = fh:read_all()
    fh:close()
    if not content or read_err then
        return false
    end

    return content:lower():find("linux") ~= nil
end

--- Returns true if `ubus` is available on the system
---@return boolean ok
local function has_ubus()
    local cmd = exec.command{
        "ubus",
        stdin = "null",
        stdout = "pipe",
        stderr = "stdout"
    }
    local _, status, code = fibers.perform(cmd:combined_output_op())
    if status == "exited" and code == 0 then
        return true
    end
    return false
end

--- Returns true if this is a supported OpenWrt system
---@return boolean
local function is_supported()
    local res = is_linux() and has_ubus()
    return res
end

return {
    is_supported = is_supported,
    backend = backend
}
