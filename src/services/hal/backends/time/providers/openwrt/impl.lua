---OpenWrt-specific TimeBackend implementation using ubus hotplug.ntp events.

-- Service modules
local log = require "services.log"
local time_types = require "services.hal.types.time"

-- Fibers modules
local op = require "fibers.op"
local exec = require "fibers.io.exec"

-- Other modules
local cjson = require "cjson.safe"

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
---  (nil, nil)         -- parse error; caller should retry with next line
---  (nil, err_string)  -- fatal error (stream closed or read error)
---
---@param line string? Line from ubus listen (nil on EOF)
---@param read_err any? Read error from the stream (nil on success)
---@return NTPEvent?
---@return string?
local function parse_ntp_event_line(line, read_err)
    -- Fatal: stream read error
    if read_err ~= nil then
        return nil, "read error: " .. tostring(read_err)
    end

    -- Fatal: EOF / stream closed
    if line == nil or line == "" then
        return nil, "stream closed"
    end

    local decoded = cjson.decode(line)
    if not decoded then
        log.warn("OpenWrt Time Backend: failed to decode hotplug.ntp event:", line)
        return nil, nil  -- non-fatal, retry
    end

    decoded = coerce_numeric_strings(decoded)
    local ntp_data = decoded["hotplug.ntp"]
    if type(ntp_data) ~= 'table' then
        log.warn("OpenWrt Time Backend: no hotplug.ntp data in event:", line)
        return nil, nil  -- non-fatal, retry
    end

    if type(ntp_data.stratum) ~= 'number' then
        log.warn("OpenWrt Time Backend: stratum field missing or not a number:", line)
        return nil, nil  -- non-fatal, retry
    end

    -- Extract fields with sensible defaults for optional fields
    local action = ntp_data.action or "unknown"
    local offset = ntp_data.offset or 0
    local freq_drift_ppm = ntp_data.freq_drift_ppm or 0

    local ntp_event, event_err = time_types.new.NTPEvent(
        ntp_data.stratum,
        action,
        offset,
        freq_drift_ppm
    )
    if not ntp_event then
        log.warn("OpenWrt Time Backend: failed to construct NTPEvent:", event_err)
        return nil, nil  -- non-fatal, retry
    end

    -- Preserve additional backend fields on the event for observability
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
    }
    local stream, stream_err = self.ntp_monitor_cmd:stdout_stream()
    if not stream then
        return false, "failed to start ubus listen: " .. tostring(stream_err)
    end

    self.ntp_monitor_stream = stream
    log.trace("OpenWrt Time Backend: NTP monitor started")
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
function OpenWrtTimeBackend:stop()
    if self.ntp_monitor_cmd then
        self.ntp_monitor_cmd:kill()
    end
    self.ntp_monitor_stream = nil
    self.ntp_monitor_cmd = nil
    log.trace("OpenWrt Time Backend: NTP monitor stopped")
    return true, ""
end

---- Constructor ----

---Create a new OpenWrt time backend.
---
---@return OpenWrtTimeBackend
local function new()
    return setmetatable({
        ntp_monitor_stream = nil,
        ntp_monitor_cmd = nil,
    }, OpenWrtTimeBackend)
end

return {
    new = new,
}
