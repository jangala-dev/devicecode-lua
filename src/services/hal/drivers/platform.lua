-- services/hal/drivers/platform.lua
--
-- Platform identity HAL driver.
-- Reads hw_revision, fw_version, serial number and board_revision at
-- driver creation and publishes them as a retained state/identity message.
-- Exposes a 'platform' capability with a 'get' RPC offering.
-- Runtime fields: 'uptime' (from /proc/uptime) and the Raspberry Pi firmware's
-- power flags (under_voltage_detected, arm_frequency_capped, currently_throttled,
-- under_voltage_occurred) from get_throttled.

local fibers  = require "fibers"
local op      = require "fibers.op"
local sleep   = require "fibers.sleep"
local file    = require "fibers.io.file"
local exec    = require "fibers.io.exec"
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

---@class PlatformDriver
---@field scope Scope
---@field control_ch Channel
---@field cap_emit_ch Channel?
---@field cache Cache
---@field identity table  hw_revision, fw_version, serial, board_revision
---@field logger Logger?
local PlatformDriver = {}
PlatformDriver.__index = PlatformDriver

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
    -- read_all can return partial content together with an error.
    if not content or read_err ~= nil then
        return nil, tostring(read_err)
    end
    return content, ""
end

---@param s string
---@return string
local function trim(s)
    return (s or ""):match("^%s*(.-)%s*$") or ""
end

local function copy_plain(t)
    local out = {}
    for k, v in pairs(t or {}) do out[k] = v end
    return out
end

--- Run fw_printenv and extract a named variable.
---@param varname string
---@return string value
local function read_fw_printenv(varname)
    local cmd = exec.command { 'fw_printenv', varname, stdin = 'null', stdout = 'pipe', stderr = 'stdout' }
    local out, _, code = perform(cmd:output_op())
    if code ~= 0 or not out then
        return ""
    end
    -- Output format: "varname=value\n"
    return trim(out:match(varname .. "=(.+)$") or "")
end

--- Read all identity fields once at driver creation.
---@return table identity
local function read_identity()
    local function safe_read(path)
        local v, _ = read_file(path)
        return trim(v or "")
    end

    local board_revision = read_fw_printenv('board_revision')

    return {
        hw_revision    = safe_read('/etc/hwrevision'),
        fw_version     = safe_read('/etc/fwversion'),
        serial         = safe_read('/data/serial'),
        board_revision = board_revision,
    }
end

--- Raspberry Pi firmware throttle state: the first readable path wins
--- (the second form is BCM2712 / CM5).
local THROTTLED_PATHS = {
    '/sys/devices/platform/soc/soc:firmware/get_throttled',
    '/sys/devices/platform/soc@107c000000/soc@107c000000:firmware/get_throttled',
}

--- get_throttled bits, as v0.10.6 reported them. On OpenWrt the file is a
--- compatibility view of the hwmon driver's cached value, which clears the
--- sticky "occurred" bits periodically, so under_voltage_occurred can miss
--- short events between reads.
local THROTTLED_BITS = {
    under_voltage_detected = 0x1,
    arm_frequency_capped   = 0x2,
    currently_throttled    = 0x4,
    under_voltage_occurred = 0x10000,
}

--- Accepts "0x50005", "50005" or "throttled=0x50005" (whole value only).
---@param raw string
---@return integer?
local function parse_throttled(raw)
    local s = trim(raw):gsub('^throttled=', '')
    local hex = s:match('^0[xX](%x+)$') or s:match('^(%x+)$')
    return hex and tonumber(hex, 16) or nil
end

--- Read get_throttled within max_age. Returns nil without an error only when no
--- candidate path exists (not a Pi); a path that exists but can't be read or
--- parsed is an error.
---@return integer|nil value
---@return string error
function PlatformDriver:_throttled(max_age)
    local cached = self.cache:get('throttled', max_age)
    if cached ~= nil then return cached, "" end
    local first_err = nil
    for _, path in ipairs(self.throttled_paths or THROTTLED_PATHS) do
        local raw, err = read_file(path)
        if raw then
            local value = parse_throttled(raw)
            if not value then return nil, "failed to parse " .. path end
            self.cache:set('throttled', value)
            return value, ""
        elseif not err:find('No such file', 1, true) then
            first_err = first_err or ("failed to read " .. path .. ": " .. err)
        end
    end
    return nil, first_err or ""
end

---- capability verbs ----

---@param opts PlatformGetOpts
---@return boolean ok
---@return any value_or_err
function PlatformDriver:get(opts)
    if opts == nil or getmetatable(opts) ~= cap_args.PlatformGetOpts then
        return false, "invalid opts"
    end
    local field   = opts.field
    local max_age = opts.max_age

    if field == 'identity' then
        return true, copy_plain(self.identity)
    end

    if self.identity and self.identity[field] ~= nil then
        return true, self.identity[field]
    end

    local mask = THROTTLED_BITS[field]
    if mask then
        local value, err = self:_throttled(max_age)
        if err ~= "" then return false, err end
        if value == nil then return true, nil end
        return true, math.floor(value / mask) % 2 == 1
    end

    if field ~= 'uptime' then
        return false, "unsupported field: " .. tostring(field)
    end

    local cached = self.cache:get('uptime', max_age)
    if cached ~= nil then
        return true, cached
    end

    local raw, err = read_file('/proc/uptime')
    if not raw then
        return false, "failed to read /proc/uptime: " .. err
    end

    local uptime_s = tonumber(raw:match("([%d%.]+)"))
    if not uptime_s then
        return false, "failed to parse /proc/uptime"
    end

    self.cache:set('uptime', uptime_s)
    return true, uptime_s
end

---- control manager ----

function PlatformDriver:control_manager()
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
function PlatformDriver:init()
    if self.initialised then
        return "already initialised"
    end
    self.initialised = true
    return ""
end

---@param emit_ch Channel
---@return Capability[]?
---@return string error
function PlatformDriver:capabilities(emit_ch)
    if not self.initialised then
        return nil, "platform driver not initialised"
    end
    self.cap_emit_ch = emit_ch
    local cap, err = cap_types.new.PlatformCapability('1', self.control_ch)
    if not cap then
        return {}, err
    end
    return { cap }, ""
end

---@return boolean ok
---@return string error
function PlatformDriver:start()
    if not self.initialised then
        return false, "platform driver not initialised"
    end
    if self.cap_emit_ch then
        -- Publish identity as a retained state sub-topic (consistent with modem state/card).
        local state_payload, state_err = hal_types.new.Emit(
            'platform', '1', 'state', 'identity', self.identity)
        if state_payload then
            self.cap_emit_ch:put(state_payload)
        else
            dlog(self.logger, 'debug', { what = 'state_identity_emit_failed', err = tostring(state_err) })
        end

        -- Publish meta.
        local meta_payload, meta_err = hal_types.new.Emit('platform', '1', 'meta', 'info', {
            provider = 'hal',
            version  = 1,
        })
        if meta_payload then
            self.cap_emit_ch:put(meta_payload)
        else
            dlog(self.logger, 'debug', { what = 'meta_emit_failed', err = tostring(meta_err) })
        end
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
function PlatformDriver:stop(timeout)
    timeout = timeout or 5
    self.scope:cancel('platform driver stopped')
    local source = perform(op.named_choice {
        join    = self.scope:join_op(),
        timeout = sleep.sleep_op(timeout),
    })
    if source == 'timeout' then
        return false, "platform driver stop timeout"
    end
    return true, ""
end

---@param logger Logger?
---@return PlatformDriver?
---@return string error
local function new(logger)
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

    local identity = read_identity()

    return setmetatable({
        scope       = scope,
        control_ch  = channel.new(CONTROL_Q_LEN),
        cap_emit_ch = nil,
        cache       = cache_mod.new(),
        identity    = identity,
        logger      = logger,
        initialised = false,
    }, PlatformDriver), ""
end

return { new = new, Driver = PlatformDriver, THROTTLED_PATHS = THROTTLED_PATHS }
