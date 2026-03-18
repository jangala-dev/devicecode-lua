local file = require "fibers.io.file"
local exec = require "fibers.io.exec"
local op = require "fibers.op"
local fibers = require "fibers"

local backend = require "services.hal.backends.modem.providers.linux_mm.impl"
local monitor = require "services.hal.backends.modem.providers.linux_mm.monitor"

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

--- Returns true if `mmcli` is runnable
---@return boolean ok
local function has_mmcli()
    local cmd = exec.command{
        "mmcli", "--version",
        stdin = "null",
        stdout = "pipe",
        stderr = "stdout"
    }
    local _, status, code, _, err = fibers.perform(cmd:combined_output_op())
    if status == "exited" and code == 0 then
        return true
    end
    return false
end

--- Returns if linux with modem manager is supported
---@return boolean
local function is_supported()
    local res = is_linux() and has_mmcli()
    return res
end

---@return ModemMonitor? monitor
---@return string error
local function new_monitor()
    return monitor.new()
end

return {
    is_supported = is_supported,
    backend = backend,
    new_monitor = new_monitor,
}

