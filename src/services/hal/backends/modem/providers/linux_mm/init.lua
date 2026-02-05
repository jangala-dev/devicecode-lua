local file = require "fibers.io.file"
local exec = require "fibers.io.exec"
local op = require "fibers.op"

local function is_linux()
    local fh = file.open("/proc/version", "r")
    if not fh then
        return false
    end

    local content = fh:read("*a")
    fh:close()
    if not content then
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
    local _, status, code, _, err = op.perform(cmd:combined_output_op())
    if status == "exited" and code == 0 then
        return true
    end
    return false
end

--- Returns if linux with modem manager is supported
---@return boolean
local function is_supported()
    return is_linux() and has_mmcli()
end

return {
    is_supported = is_supported,
    backend = backend
}

