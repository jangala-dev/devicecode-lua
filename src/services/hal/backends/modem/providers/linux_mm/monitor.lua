local exec = require "fibers.io.exec"
local op = require "fibers.op"
local modem_types = require "services.hal.types.modem"

---@class ModemMonitor
---@field cmd Command
---@field stream any
local ModemMonitor = {}
ModemMonitor.__index = ModemMonitor

--- Parse one line from `mmcli -M` output into a ModemMonitorEvent.
--- Returns (nil, "Command closed") when the stream yields nil (end of stream).
--- Returns (nil, error) for lines that cannot be parsed.
---@param line string?
---@return ModemMonitorEvent?
---@return string error
local function parse_monitor_line(line)
    if not line then
        return nil, "Command closed"
    end

    local status, address = line:match("^(.-)(/org%S+)")
    if not address then
        return nil, "line could not be parsed: " .. tostring(line)
    end

    local is_added = not status:match("-")
    local event, err = modem_types.new.ModemMonitorEvent(is_added, address)
    if not event then
        return nil, "failed to create monitor event: " .. tostring(err)
    end

    return event, ""
end

--- Returns an Op that when performed yields the next ModemMonitorEvent.
--- (nil, "Command closed") signals end of stream.
--- (nil, error) signals an unparseable line — the caller should continue looping.
---@return Op
function ModemMonitor:next_event_op()
    return op.guard(function()
        return self.stream:read_line_op():wrap(parse_monitor_line)
    end)
end

--- Create and start a new ModemMonitor backed by `mmcli -M`.
---@return ModemMonitor? monitor
---@return string error
local function new()
    local cmd = exec.command {
        "mmcli", "-M",
        stdin = "null",
        stdout = "pipe",
        stderr = "stdout"
    }
    local stream, err = cmd:stdout_stream()
    if not stream then
        return nil, "failed to start modem monitor: " .. tostring(err)
    end
    return setmetatable({ cmd = cmd, stream = stream }, ModemMonitor), ""
end

return {
    new = new,
}
