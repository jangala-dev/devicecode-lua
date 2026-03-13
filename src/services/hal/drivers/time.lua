-- HAL modules
local hal_types = require "services.hal.types.core"
local cap_types = require "services.hal.types.capabilities"

-- Backend modules
local ubus_backend = require "services.hal.backends.ubus"

-- Service modules
local log = require "services.log"

-- Fibers modules
local fibers = require "fibers"
local op = require "fibers.op"
local channel = require "fibers.channel"
local sleep = require "fibers.sleep"
local exec = require "fibers.io.exec"

-- Other modules
local cjson = require "cjson.safe"
local uuid = require "uuid"

---@class TimeDriver
---@field id CapabilityId UUID for this time source capability
---@field cap_emit_ch Channel Capability emit channel (Emit messages)
---@field scope Scope Child scope owning the monitor fiber
---@field control_ch Channel RPC control channel (no offerings currently, reserved)
---@field initialised boolean
---@field caps_applied boolean
---@field synced boolean Tracks last known sync state to detect transitions
local TimeDriver = {}
TimeDriver.__index = TimeDriver

---- Constants ----

local DEFAULT_STOP_TIMEOUT = 5
local CONTROL_Q_LEN = 4

---- Internal Utilities ----

---Emit a capability state, meta, or event via the cap emit channel.
---@param emit_ch Channel
---@param id CapabilityId
---@param mode EmitMode
---@param key string
---@param data any
---@return boolean ok
---@return string? error
local function emit(emit_ch, id, mode, key, data)
    local payload, err = hal_types.new.Emit('time', id, mode, key, data)
    if not payload then
        return false, err
    end
    emit_ch:put(payload)
    return true
end

---Convert NTP stratum to an estimated absolute accuracy in seconds.
---Returns nil when unsynced (stratum >= 16) or invalid input.
---@param stratum number
---@return number? accuracy_seconds
local function accuracy_for_stratum(stratum)
    if type(stratum) ~= 'number' then
        return nil
    end
    if stratum >= 16 then
        return nil
    end

    -- Coarse operational heuristic:
    -- lower stratum generally implies lower clock error.
    if stratum <= 1 then
        return 0.001
    elseif stratum <= 4 then
        return 0.01
    elseif stratum <= 8 then
        return 0.1
    else
        return 1.0
    end
end

---Build a meta payload table for this time source.
---@param accuracy_seconds number?
---@return table
local function build_meta(accuracy_seconds)
    return {
        provider = 'hal',
        source   = 'ntp',
        version  = 1,
        accuracy_seconds = accuracy_seconds,
    }
end

---- Monitor Fiber ----

---Listen to `ubus listen hotplug.ntp` output and emit state/events via the cap
---emit channel. Runs in self.scope. Exits on stream close, read error, or scope
---cancellation. Transition events (synced/unsynced) are non-retained; the current
---sync state is always published as a retained state emit on every hotplug event.
---@return nil
function TimeDriver:_ntpd_monitor()
    fibers.current_scope():finally(function()
        log.trace("Time Driver: ntpd monitor exiting")
    end)

    log.trace("Time Driver: ntpd monitor started")

    -- exec.command is bound to the current scope (self.scope) automatically.
    -- When self.scope is cancelled the process is terminated, causing read_line to
    -- return nil/error and the loop below exits cleanly.
    local listen_cmd = ubus_backend.listen('hotplug.ntp')
    local stdout, stream_err = listen_cmd:stdout_stream()
    if not stdout then
        error("Time Driver: failed to start ubus listen: " .. tostring(stream_err))
    end

    while true do
        local line, read_err = stdout:read_line()
        if read_err then
            log.error("Time Driver: ubus listen read error:", read_err)
            break
        end
        if line == nil then
            log.warn("Time Driver: ubus listen stream closed unexpectedly")
            break
        end

        -- ubus listen output is one JSON object per line:
        -- { "hotplug.ntp": { "stratum": <n> } }
        local decoded = cjson.decode(line)
        if not decoded then
            log.warn("Time Driver: failed to decode hotplug.ntp event:", line)
        else
            local ntp_data = decoded["hotplug.ntp"]
            if type(ntp_data) == 'table' and type(ntp_data.stratum) == 'number' then
                local stratum = ntp_data.stratum
                local now_synced = stratum ~= 16
                local was_synced = self.synced
                local accuracy_seconds = accuracy_for_stratum(stratum)

                -- Always update retained state, even if sync status did not change,
                -- so that the latest stratum value is always visible to subscribers.
                local ok, emit_err = emit(
                    self.cap_emit_ch, self.id, 'state', 'synced',
                    {
                        synced = now_synced,
                        stratum = stratum,
                        accuracy_seconds = accuracy_seconds,
                    }
                )
                if not ok then
                    log.warn("Time Driver: failed to emit state:", emit_err)
                end

                -- Update accuracy metadata only on a sync/unsync transition.
                if now_synced ~= was_synced then
                    local meta_ok, meta_err = emit(
                        self.cap_emit_ch, self.id, 'meta', 'source',
                        build_meta(accuracy_seconds)
                    )
                    if not meta_ok then
                        log.warn("Time Driver: failed to emit meta:", meta_err)
                    end
                end

                -- Emit non-retained transition events.
                if now_synced and not was_synced then
                    log.debug("Time Driver: NTP synced, stratum =", stratum)
                    local ev_ok, ev_err = emit(
                        self.cap_emit_ch, self.id, 'event', 'synced',
                        {
                            stratum = stratum,
                            accuracy_seconds = accuracy_seconds,
                        }
                    )
                    if not ev_ok then
                        log.warn("Time Driver: failed to emit synced event:", ev_err)
                    end
                elseif not now_synced and was_synced then
                    log.debug("Time Driver: NTP unsynced, stratum =", stratum)
                    local ev_ok, ev_err = emit(
                        self.cap_emit_ch, self.id, 'event', 'unsynced',
                        {
                            stratum = stratum,
                            accuracy_seconds = accuracy_seconds,
                        }
                    )
                    if not ev_ok then
                        log.warn("Time Driver: failed to emit unsynced event:", ev_err)
                    end
                end

                self.synced = now_synced
            else
                log.warn("Time Driver: received unexpected hotplug.ntp payload:", line)
            end
        end
    end
end

---- Driver Lifecycle ----

---Initialise the time driver. Restarts sysntpd and marks the driver as initialised.
---Must be called from inside a fiber.
---@return string error Empty string on success.
function TimeDriver:init()
    log.trace("Time Driver: initialising, restarting sysntpd")

    local status, code, _, err = fibers.perform(
        exec.command("/etc/init.d/sysntpd", "restart"):run_op()
    )
    if status ~= 'exited' or code ~= 0 then
        return "sysntpd restart failed: " .. tostring(err or ("exit code " .. tostring(code)))
    end

    self.initialised = true
    log.trace("Time Driver: sysntpd restarted successfully")
    return ""
end

---Connect the driver to the capability emit channel and return the capability list.
---Must be called after init() and before start().
---@param cap_emit_ch Channel
---@return Capability[]? capabilities
---@return string error Empty string on success.
function TimeDriver:capabilities(cap_emit_ch)
    if not self.initialised then
        return nil, "driver not initialised"
    end

    self.cap_emit_ch = cap_emit_ch

    local cap, cap_err = cap_types.new.TimeCapability(self.id, self.control_ch)
    if not cap then
        return nil, "failed to create time capability: " .. tostring(cap_err)
    end

    self.caps_applied = true
    return { cap }, ""
end

---Start the time driver. Emits initial meta and state, then spawns the NTP monitor
---fiber. Must be called after capabilities().
---@return boolean ok
---@return string? error
function TimeDriver:start()
    if not self.initialised then
        return false, "driver not initialised"
    end
    if not self.caps_applied then
        return false, "capabilities not applied"
    end

    -- Publish initial meta (accuracy unknown until first NTP update).
    local meta_ok, meta_err = emit(
        self.cap_emit_ch, self.id, 'meta', 'source',
        build_meta(nil)
    )
    if not meta_ok then
        log.warn("Time Driver: failed to emit initial meta:", meta_err)
    end

    -- Publish initial retained state: not yet synced, stratum unknown.
    local state_ok, state_err = emit(
        self.cap_emit_ch, self.id, 'state', 'synced',
        { synced = false, stratum = nil }
    )
    if not state_ok then
        log.warn("Time Driver: failed to emit initial state:", state_err)
    end

    self.scope:spawn(function() self:_ntpd_monitor() end)

    log.trace("Time Driver: started")
    return true, nil
end

---Stop the time driver. Cancels the driver scope, terminating the NTP monitor fiber
---and any running ubus listen process.
---@param timeout number? Timeout in seconds. Defaults to 5.
---@return boolean ok
---@return string? error
function TimeDriver:stop(timeout)
    timeout = timeout or DEFAULT_STOP_TIMEOUT
    self.scope:cancel()

    local source = fibers.perform(op.named_choice {
        join    = self.scope:join_op(),
        timeout = sleep.sleep_op(timeout),
    })

    if source == 'timeout' then
        return false, "time driver stop timeout"
    end
    return true, nil
end

---- Constructor ----

---Create a new TimeDriver instance. Generates a UUID for the capability id and
---creates a child scope. Must be called from inside a fiber.
---@return TimeDriver? driver
---@return string error Empty string on success.
local function new()
    local scope, sc_err = fibers.current_scope():child()
    if not scope then
        return nil, "failed to create child scope: " .. tostring(sc_err)
    end

    return setmetatable({
        id           = uuid.new(),
        cap_emit_ch  = nil,
        scope        = scope,
        control_ch   = channel.new(CONTROL_Q_LEN),
        initialised  = false,
        caps_applied = false,
        synced       = false,
    }, TimeDriver), ""
end

return {
    new = new,
}
