-- services/hal/drivers/thermal.lua
--
-- Thermal zone HAL driver.
-- One driver instance per sysfs thermal zone (e.g. /sys/class/thermal/thermal_zone0).
-- Exposes a 'thermal' capability with a 'get' RPC offering.
-- Zone type is read once at startup for meta.  Temperature is read on
-- cache miss by reading the sysfs 'temp' file (millidegrees → degrees C).

local fibers  = require "fibers"
local op      = require "fibers.op"
local sleep   = require "fibers.sleep"
local file    = require "fibers.io.file"
local channel = require "fibers.channel"

local hal_types = require "services.hal.types.core"
local cap_types      = require "services.hal.types.capabilities"
local cap_args = require "services.hal.types.capability_args"
local cache_mod      = require "shared.cache"

local perform = fibers.perform

local CONTROL_Q_LEN = 8

local function dlog(logger, level, payload)
    if logger and logger[level] then
        logger[level](logger, payload)
    end
end

---@class ThermalDriver
---@field zone_id string       e.g. "zone0"
---@field sysfs_dir string     e.g. "/sys/class/thermal/thermal_zone0"
---@field zone_type string?    read from sysfs 'type' file
---@field scope Scope
---@field control_ch Channel
---@field cap_emit_ch Channel?
---@field cache Cache
---@field logger Logger?
local ThermalDriver = {}
ThermalDriver.__index = ThermalDriver

---- helpers ----

---@param path string
---@return string? content
---@return string error
local function read_file(path)
    local f, open_err = file.open(path, 'r')
    if not f then
        return nil, tostring(open_err)
    end
    local content, read_err = f:read_all()
    f:close()
    if not content then
        return nil, tostring(read_err)
    end
    return content, ""
end

--- Read the zone's type string (e.g. "cpu-thermal").
---@param sysfs_dir string
---@param logger Logger?
---@return string? zone_type
local function read_zone_type(sysfs_dir, logger)
    local raw, err = read_file(sysfs_dir .. '/type')
    if not raw then
        dlog(logger, 'debug', { what = 'zone_type_read_failed', err = tostring(err), path = sysfs_dir .. '/type' })
        return nil
    end
    return raw:match("^%s*(.-)%s*$")
end

---- capability verbs ----

---@param opts ThermalGetOpts
---@return boolean ok
---@return any value_or_err
function ThermalDriver:get(opts)
    if opts == nil or getmetatable(opts) ~= cap_args.ThermalGetOpts then
        return false, "invalid opts"
    end
    local max_age = opts.max_age

    local cached = self.cache:get('temp', max_age)
    if cached ~= nil then
        return true, cached
    end

    local raw, err = read_file(self.sysfs_dir .. '/temp')
    if not raw then
        return false, "failed to read temperature: " .. err
    end

    local millideg = tonumber(raw:match("%d+"))
    if not millideg then
        return false, "failed to parse temperature value"
    end

    local temp_c = millideg / 1000
    self.cache:set('temp', temp_c)
    return true, temp_c
end

---- control manager ----

function ThermalDriver:control_manager()
    fibers.current_scope():finally(function()
        dlog(self.logger, 'debug', { what = 'control_manager_exiting' })
    end)

    while true do
        local request, req_err = self.control_ch:get()
        if not request then
            dlog(self.logger, 'debug', { what = 'control_ch_closed', err = tostring(req_err) })
            break
        end

        local fn = self[request.verb]
        local ok, value_or_err
        if type(fn) ~= 'function' then
            ok, value_or_err = false, "unsupported verb: " .. tostring(request.verb)
        else
            local st, _, r1, r2 = fibers.run_scope(function()
                return fn(self, request.opts)
            end)
            if st ~= 'ok' then
                ok, value_or_err = false, "internal error: " .. tostring(r1)
            else
                ok, value_or_err = r1, r2
            end
        end

        local reply = hal_types.new.Reply(ok, value_or_err)
        if reply then
            request.reply_ch:put(reply)
        end
    end
end

---- public interface ----

---@return string error
function ThermalDriver:init()
    if self.initialised then
        return "already initialised"
    end
    self.initialised = true
    return ""
end

---@param emit_ch Channel
---@return Capability[]?
---@return string error
function ThermalDriver:capabilities(emit_ch)
    if not self.initialised then
        return nil, "thermal driver not initialised"
    end
    self.cap_emit_ch = emit_ch
    local cap, err = cap_types.new.ThermalCapability(self.zone_id, self.control_ch)
    if not cap then
        return {}, err
    end
    return { cap }, ""
end

---@return boolean ok
---@return string error
function ThermalDriver:start()
    if not self.initialised then
        return false, "thermal driver not initialised"
    end
    local meta_payload, emit_err = hal_types.new.Emit('thermal', self.zone_id, 'meta', 'info', {
        provider  = 'hal',
        version   = 1,
        zone      = self.zone_id,
        path      = self.sysfs_dir,
        zone_type = self.zone_type,
    })
    if meta_payload and self.cap_emit_ch then
        self.cap_emit_ch:put(meta_payload)
    elseif not meta_payload then
        dlog(self.logger, 'debug', { what = 'meta_emit_failed', err = tostring(emit_err) })
    end

    local ok, spawn_err = self.scope:spawn(function()
        self:control_manager()
    end)
    if not ok then
        return false, "failed to spawn control_manager: " .. tostring(spawn_err)
    end
    return true, ""
end

---@param timeout number?
---@return boolean ok
---@return string error
function ThermalDriver:stop(timeout)
    timeout = timeout or 5
    self.scope:cancel(('thermal driver [%s] stopped'):format(self.zone_id))
    local source = perform(op.named_choice {
        join    = self.scope:join_op(),
        timeout = sleep.sleep_op(timeout),
    })
    if source == 'timeout' then
        return false, ("thermal driver [%s] stop timeout"):format(self.zone_id)
    end
    return true, ""
end

---@param zone_id string    canonical zone id, e.g. "zone0"
---@param sysfs_dir string  full path to zone sysfs dir, e.g. "/sys/class/thermal/thermal_zone0"
---@param logger Logger?
---@return ThermalDriver?
---@return string error
local function new(zone_id, sysfs_dir, logger)
    assert(type(zone_id) == 'string' and zone_id ~= '', "zone_id must be a non-empty string")
    assert(type(sysfs_dir) == 'string' and sysfs_dir ~= '', "sysfs_dir must be a non-empty string")

    local scope, err = fibers.current_scope():child()
    if not scope then
        return nil, "failed to create child scope: " .. tostring(err)
    end

    scope:finally(function()
        local st, primary = scope:status()
        if st == 'failed' then
            dlog(logger, 'error', { what = 'scope_failed', err = tostring(primary), status = st })
        end
        dlog(logger, 'debug', { what = 'stopped' })
    end)

    local zone_type = read_zone_type(sysfs_dir, logger)

    return setmetatable({
        zone_id     = zone_id,
        sysfs_dir   = sysfs_dir,
        zone_type   = zone_type,
        scope       = scope,
        control_ch  = channel.new(CONTROL_Q_LEN),
        cap_emit_ch = nil,
        cache       = cache_mod.new(),
        logger      = logger,
        initialised = false,
    }, ThermalDriver), ""
end

return { new = new }
