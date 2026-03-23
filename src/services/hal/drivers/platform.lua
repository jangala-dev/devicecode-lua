-- services/hal/drivers/platform.lua
--
-- Platform identity HAL driver.
-- Reads hw_revision, fw_version, serial number and board_revision at
-- driver creation and publishes them as a retained state/identity message.
-- Exposes a 'platform' capability with a 'get' RPC offering.
-- Only the 'uptime' field is readable at runtime (from /proc/uptime).

local fibers  = require "fibers"
local op      = require "fibers.op"
local sleep   = require "fibers.sleep"
local file    = require "fibers.io.file"
local exec    = require "fibers.io.exec"
local channel = require "fibers.channel"

local hal_types = require "services.hal.types.core"
local cap_types      = require "services.hal.types.capabilities"
local external_types = require "services.hal.types.external"
local cache_mod      = require "shared.cache"
local log            = require "services.log"

local perform = fibers.perform

local CONTROL_Q_LEN = 8

---@class PlatformDriver
---@field scope Scope
---@field control_ch Channel
---@field cap_emit_ch Channel?
---@field cache Cache
---@field identity table  hw_revision, fw_version, serial, board_revision
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
    if not content then
        return nil, tostring(read_err)
    end
    return content, ""
end

---@param s string
---@return string
local function trim(s)
    return (s or ""):match("^%s*(.-)%s*$") or ""
end

--- Run fw_printenv and extract a named variable.
---@param varname string
---@return string value
local function read_fw_printenv(varname)
    local cmd = exec.command('fw_printenv', varname)
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

---- capability verbs ----

---@param opts PlatformGetOpts
---@return boolean ok
---@return any value_or_err
function PlatformDriver:get(opts)
    if opts == nil or getmetatable(opts) ~= external_types.PlatformGetOpts then
        return false, "invalid opts"
    end
    local field   = opts.field
    local max_age = opts.max_age

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
        log.trace("Platform Driver: control_manager exiting")
    end)

    while true do
        local request, req_err = self.control_ch:get()
        if not request then
            log.debug("Platform Driver: control_ch closed:", req_err)
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
            log.debug("Platform Driver: state/identity emit failed:", state_err)
        end

        -- Publish meta.
        local meta_payload, meta_err = hal_types.new.Emit('platform', '1', 'meta', 'info', {
            provider = 'hal',
            version  = 1,
        })
        if meta_payload then
            self.cap_emit_ch:put(meta_payload)
        else
            log.debug("Platform Driver: meta emit failed:", meta_err)
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

---@return PlatformDriver?
---@return string error
local function new()
    local scope, err = fibers.current_scope():child()
    if not scope then
        return nil, "failed to create child scope: " .. tostring(err)
    end

    scope:finally(function()
        local st, primary = scope:status()
        if st == 'failed' then
            log.error(("Platform Driver: error - %s"):format(tostring(primary)))
        end
        log.trace("Platform Driver: stopped")
    end)

    local identity = read_identity()

    return setmetatable({
        scope       = scope,
        control_ch  = channel.new(CONTROL_Q_LEN),
        cap_emit_ch = nil,
        cache       = cache_mod.new(),
        identity    = identity,
        initialised = false,
    }, PlatformDriver), ""
end

return { new = new }
