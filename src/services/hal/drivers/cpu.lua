-- services/hal/drivers/cpu.lua
--
-- CPU HAL driver.
-- Exposes a single 'cpu' capability with a 'get' RPC offering.
-- Reads utilisation from /proc/stat (double-sample, 1-second gap) and
-- frequency from /sys/devices/system/cpu/cpuN/cpufreq/scaling_cur_freq.
-- CPU model and core count are read once from /proc/cpuinfo at driver
-- creation and included in meta.

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

local CONTROL_Q_LEN  = 8
local FREQ_SYSFS_FMT = '/sys/devices/system/cpu/cpu%d/cpufreq/scaling_cur_freq'

local function dlog(logger, level, payload)
    if logger and logger[level] then
        logger[level](logger, payload)
    end
end

---@class CpuDriver
---@field scope Scope
---@field control_ch Channel
---@field cap_emit_ch Channel?
---@field cache Cache
---@field model string
---@field core_count number
---@field logger Logger?
local CpuDriver = {}
CpuDriver.__index = CpuDriver

---- helpers ----

---@param path string
---@return string? content
---@return string err
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

--- Parse /proc/cpuinfo for the first model name and core count.
---@param logger Logger?
---@return string model
---@return number core_count
local function read_cpuinfo(logger)
    local content, err = read_file('/proc/cpuinfo')
    if not content then
        dlog(logger, 'warn', { what = 'cpuinfo_read_failed', err = tostring(err) })
        return "", 1
    end
    local model = content:match("model name%s*:%s*([^\n]+)") or ""
    local count = 0
    for _ in content:gmatch("processor%s*:") do
        count = count + 1
    end
    return model:match("^%s*(.-)%s*$") or model, math.max(count, 1)
end

--- Parse /proc/stat cpu lines into {user, nice, system, idle, ...} tables.
---@param content string
---@return table<string, table>
local function parse_stat(content)
    local result = {}
    for line in content:gmatch("[^\n]+") do
        local name, rest = line:match("^(cpu%w*)%s+(.+)$")
        if name then
            local fields = {}
            for n in rest:gmatch("%d+") do
                fields[#fields + 1] = tonumber(n)
            end
            result[name] = fields
        end
    end
    return result
end

--- Compute utilisation (%) from two successive /proc/stat snapshots.
---@param s1 table
---@param s2 table
---@return number util percentage 0-100
local function compute_util(s1, s2)
    local total1, total2, idle1, idle2 = 0, 0, (s1[4] or 0), (s2[4] or 0)
    for _, v in ipairs(s1) do total1 = total1 + v end
    for _, v in ipairs(s2) do total2 = total2 + v end
    local delta_total = total2 - total1
    local delta_idle  = idle2 - idle1
    if delta_total == 0 then return 0 end
    return math.max(0, math.min(100, (1 - delta_idle / delta_total) * 100))
end

---- capability verbs ----

local VALID_FIELDS = { utilisation = true, core_utilisations = true, frequency = true, core_frequencies = true }

---@param opts CpuGetOpts
---@return boolean ok
---@return any value_or_err
function CpuDriver:get(opts)
    if opts == nil or getmetatable(opts) ~= cap_args.CpuGetOpts then
        return false, "invalid opts"
    end
    local field   = opts.field
    local max_age = opts.max_age

    if not VALID_FIELDS[field] then
        return false, "unsupported field: " .. tostring(field)
    end

    local cached = self.cache:get(field, max_age)
    if cached ~= nil then
        return true, cached
    end

    -- Utilisation pair: double-sample /proc/stat with 1-second sleep.
    if field == 'utilisation' or field == 'core_utilisations' then
        local s1_raw, err1 = read_file('/proc/stat')
        if not s1_raw then
            return false, "failed to read /proc/stat: " .. err1
        end
        local s1 = parse_stat(s1_raw)
        perform(sleep.sleep_op(1))
        local s2_raw, err2 = read_file('/proc/stat')
        if not s2_raw then
            return false, "failed to read /proc/stat (2nd sample): " .. err2
        end
        local s2 = parse_stat(s2_raw)

        local overall = compute_util(s1['cpu'] or {}, s2['cpu'] or {})
        local per_core = {}
        for i = 0, self.core_count - 1 do
            local key = 'cpu' .. i
            per_core[key] = compute_util(s1[key] or {}, s2[key] or {})
        end

        self.cache:set('utilisation', overall)
        self.cache:set('core_utilisations', per_core)
        if field == 'utilisation' then
            return true, overall
        end
        return true, per_core
    end

    -- Frequency pair: read scaling_cur_freq for each core.
    if field == 'frequency' or field == 'core_frequencies' then
        local per_core = {}
        local total = 0
        local count = 0
        for i = 0, self.core_count - 1 do
            local path = FREQ_SYSFS_FMT:format(i)
            local raw, ferr = read_file(path)
            if raw then
                local khz = tonumber(raw:match("%d+"))
                if khz then
                    local key = 'cpu' .. i
                    per_core[key] = khz
                    total = total + khz
                    count = count + 1
                end
            else
                dlog(self.logger, 'debug', { what = 'frequency_read_skipped', path = path, err = tostring(ferr) })
            end
        end
        local avg = (count > 0) and (total / count) or 0

        self.cache:set('frequency', avg)
        self.cache:set('core_frequencies', per_core)
        if field == 'frequency' then
            return true, avg
        end
        return true, per_core
    end

    return false, "unreachable"
end

---- control manager ----

function CpuDriver:control_manager()
    fibers.current_scope():finally(function()
        dlog(self.logger, 'debug', { what = 'control_manager_exiting' })
    end)

    while true do
        local request, req_err = self.control_ch:get()
        if not request then
            dlog(self.logger, 'debug', { what = 'control_ch_closed', err = tostring(req_err) })
            break
        end
        ---@cast request ControlRequest

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

---- emit helpers ----

---@param mode EmitMode
---@param key string
---@param data any
function CpuDriver:_emit(mode, key, data)
    if not self.cap_emit_ch then return end
    local payload, err = hal_types.new.Emit('cpu', '1', mode, key, data)
    if not payload then
        dlog(self.logger, 'debug', { what = 'emit_failed', key = key, err = tostring(err) })
        return
    end
    self.cap_emit_ch:put(payload)
end

---- public interface ----

---@return string error
function CpuDriver:init()
    if self.initialised then
        return "already initialised"
    end
    self.initialised = true
    return ""
end

---@param emit_ch Channel
---@return Capability[]
---@return string error
function CpuDriver:capabilities(emit_ch)
    if not self.initialised then
        return {}, "cpu driver not initialised"
    end
    self.cap_emit_ch = emit_ch
    local cap, err = cap_types.new.CpuCapability('1', self.control_ch)
    if not cap then
        return {}, err
    end
    return { cap }, ""
end

---@return boolean ok
---@return string error
function CpuDriver:start()
    if not self.initialised then
        return false, "cpu driver not initialised"
    end
    self:_emit('meta', 'info', {
        provider   = 'hal',
        version    = 1,
        model      = self.model,
        core_count = self.core_count,
    })

    local ok, err = self.scope:spawn(function()
        self:control_manager()
    end)
    if not ok then
        return false, "failed to spawn control_manager: " .. tostring(err)
    end
    return true, ""
end

---@param timeout number?
---@return boolean ok
---@return string error
function CpuDriver:stop(timeout)
    timeout = timeout or 5
    self.scope:cancel('cpu driver stopped')
    local source = perform(op.named_choice {
        join    = self.scope:join_op(),
        timeout = sleep.sleep_op(timeout),
    })
    if source == 'timeout' then
        return false, "cpu driver stop timeout"
    end
    return true, ""
end

---@param logger Logger?
---@return CpuDriver?
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

    local model, core_count = read_cpuinfo(logger)

    return setmetatable({
        scope       = scope,
        control_ch  = channel.new(CONTROL_Q_LEN),
        cap_emit_ch = nil,
        cache       = cache_mod.new(),
        model       = model,
        core_count  = core_count,
        logger      = logger,
        initialised = false,
    }, CpuDriver), ""
end

return { new = new }
