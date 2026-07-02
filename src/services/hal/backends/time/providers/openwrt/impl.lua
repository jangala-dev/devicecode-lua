---OpenWrt-specific TimeBackend implementation using ubus hotplug.ntp events.

-- Service modules
local time_types = require "services.hal.types.time"

-- Fibers modules
local op = require "fibers.op"
local exec = require "fibers.io.exec"

-- Other modules
local cjson = require "cjson.safe"

local function owned_process_flags()
    local flags = { process_group = true }
    if type(exec.supports) == 'function' and exec.supports('parent_death_signal') then
        flags.parent_death_signal = 'TERM'
    end
    return flags
end

local function terminate_command(cmd, sig)
    if not cmd or type(cmd.kill) ~= 'function' then return true, nil end
    local ok, a, b = pcall(function() return cmd:kill(sig or 15) end)
    if not ok then return nil, tostring(a) end
    if a == false or a == nil then return nil, tostring(b or 'command kill failed') end
    return true, nil
end

local function shutdown_command_op(cmd, timeout)
    return op.guard(function()
        if not cmd then return op.always(true, '') end
        return cmd:shutdown_op(timeout or 0.2):wrap(function(status, _code, _sig, err)
            if status == 'exited' or status == 'signalled' then
                return true, ''
            end
            return false, err or ('command shutdown failed: ' .. tostring(status))
        end)
    end)
end

---@class OpenWrtTimeBackend : TimeBackend
---@field ntp_monitor_stream Stream? Current ubus listen stream
---@field ntp_monitor_cmd Command? Current ubus listen command
local OpenWrtTimeBackend = {}
OpenWrtTimeBackend.__index = OpenWrtTimeBackend

---- Private Utilities ----

---Recursively convert numeric-looking strings into numbers.
---@param value any
---@return any
local function coerce_numeric_strings(value)
    if type(value) == 'string' then
        local n = tonumber(value)
        if n ~= nil then
            return n
        end
        return value
    end

    if type(value) == 'table' then
        for k, v in pairs(value) do
            value[k] = coerce_numeric_strings(v)
        end
        return value
    end

    return value
end

---Parse a single ubus listen hotplug.ntp line into a strongly typed NTPEvent.
---
---Called as a wrap function on read_line_op(), receiving (line, read_err).
---Returns:
---  (NTPEvent, nil)    -- success
---  (nil, err_string)  -- fatal error; caller should break the monitor loop
---
---@param line string?
---@param read_err any?
---@return any?
---@return string?
local function parse_ntp_event_line(line, read_err)
    if read_err ~= nil then
        return nil, "read error: " .. tostring(read_err)
    end

    if line == nil or line == "" then
        return nil, "stream closed"
    end

    local decoded = cjson.decode(line)
    if not decoded then
        return nil, "decode failed: " .. line
    end

    decoded = coerce_numeric_strings(decoded)
    local ntp_data = decoded["hotplug.ntp"]
    if type(ntp_data) ~= 'table' then
        return nil, "missing hotplug.ntp key: " .. line
    end

    if type(ntp_data.stratum) ~= 'number' then
        return nil, "invalid stratum: " .. line
    end

    local action        = ntp_data.action or "unknown"
    local offset        = ntp_data.offset or 0
    local freq_drift_ppm = ntp_data.freq_drift_ppm or 0

    local ntp_event, event_err = time_types.new.NTPEvent(
        ntp_data.stratum,
        action,
        offset,
        freq_drift_ppm
    )
    if not ntp_event then
        return nil, "NTPEvent construction failed: " .. tostring(event_err)
    end

    for k, v in pairs(ntp_data) do
        if ntp_event[k] == nil then
            ntp_event[k] = v
        end
    end

    return ntp_event, nil
end

---- Backend Lifecycle ----

---Start monitoring NTP synchronization events via ubus hotplug.ntp.
---
---@return boolean ok
---@return string error Empty string on success.
function OpenWrtTimeBackend:start_ntp_monitor()
    if self.ntp_monitor_cmd then
        return false, "NTP monitor already running"
    end

    -- Start ubus listen command bound to current scope
    self.ntp_monitor_cmd = exec.command{
        'ubus', 'listen', 'hotplug.ntp',
        stdin  = 'null',
        stdout = 'pipe',
        stderr = 'null',
        shutdown_grace = 0.2,
        flags = owned_process_flags(),
    }
    local stream, stream_err = self.ntp_monitor_cmd:stdout_stream()
    if not stream then
        return false, "failed to start ubus listen: " .. tostring(stream_err)
    end

    self.ntp_monitor_stream = stream
    return true, ""
end

---Get an operation that yields the next NTP event from the hotplug.ntp stream.
---
---Returns (NTPEvent, nil) on success, (nil, nil) on a parse error (caller should
---retry), or (nil, err_string) on a fatal error (stream closed or read error).
---
---@return Op
function OpenWrtTimeBackend:ntp_event_op()
    return op.guard(function()
        if not self.ntp_monitor_stream then
            error("NTP monitor not started")
        end
        return self.ntp_monitor_stream:read_line_op():wrap(parse_ntp_event_line)
    end)
end

---Stop the NTP monitor and clean up resources.
---
---@return boolean ok
---@return string error
function OpenWrtTimeBackend:terminate(reason)
    local stream = self.ntp_monitor_stream
    local cmd = self.ntp_monitor_cmd
    self.ntp_monitor_stream = nil
    self.ntp_monitor_cmd = nil
    if stream then pcall(function() stream:terminate(reason or 'ntp monitor terminated') end) end
    return terminate_command(cmd, 15)
end

function OpenWrtTimeBackend:shutdown_op(timeout)
    return op.guard(function()
        local stream = self.ntp_monitor_stream
        local cmd = self.ntp_monitor_cmd
        self.ntp_monitor_stream = nil
        self.ntp_monitor_cmd = nil
        if stream then pcall(function() stream:terminate('ntp monitor stopped') end) end
        return shutdown_command_op(cmd, timeout or 0.2)
    end)
end

function OpenWrtTimeBackend:stop()
    local fibers = require 'fibers'
    return fibers.perform(self:shutdown_op(0.2))
end

---- Constructor ----

---Create a new OpenWrt time backend.
---
---@return OpenWrtTimeBackend
local function new()
    return setmetatable({
        ntp_monitor_stream = nil,
        ntp_monitor_cmd    = nil,
    }, OpenWrtTimeBackend)
end

return {
    new = new,
}
