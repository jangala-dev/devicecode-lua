-- services/hal/drivers/memory.lua
--
-- Memory HAL driver.
-- Exposes a single 'memory' capability with a 'get' RPC offering.
-- Reads from /proc/meminfo on each cache miss, computing all four
-- fields at once (total, used, free, util).

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

---@class MemoryDriver
---@field scope Scope
---@field control_ch Channel
---@field cap_emit_ch Channel?
---@field cache Cache
---@field logger Logger?
local MemoryDriver = {}
MemoryDriver.__index = MemoryDriver

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

--- Parse /proc/meminfo and compute total, free, used, util.
---@return table? result
---@return string error
local function read_meminfo()
    local content, err = read_file('/proc/meminfo')
    if not content then
        return nil, "failed to read /proc/meminfo: " .. err
    end

    local function kv(key)
        local v = content:match(key .. "%s*:%s*(%d+)")
        return v and tonumber(v) or 0
    end

    local mem_total   = kv("MemTotal")
    local mem_free    = kv("MemFree")
    local buffers     = kv("Buffers")
    local cached      = kv("Cached")

    local effective_free = mem_free + buffers + cached
    local used           = mem_total - effective_free
    local util           = (mem_total > 0) and (used / mem_total * 100) or 0

    return { total = mem_total, used = used, free = effective_free, util = util }, ""
end

---- capability verbs ----

local VALID_FIELDS = { total = true, used = true, free = true, util = true }

---@param opts MemoryGetOpts
---@return boolean ok
---@return any value_or_err
function MemoryDriver:get(opts)
    if opts == nil or getmetatable(opts) ~= cap_args.MemoryGetOpts then
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

    local info, err = read_meminfo()
    if not info then
        return false, err
    end

    -- Populate all four cache entries at once.
    self.cache:set('total', info.total)
    self.cache:set('used',  info.used)
    self.cache:set('free',  info.free)
    self.cache:set('util',  info.util)

    return true, info[field]
end

---- control manager ----

function MemoryDriver:control_manager()
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
function MemoryDriver:init()
    if self.initialised then
        return "already initialised"
    end
    self.initialised = true
    return ""
end

---@param emit_ch Channel
---@return Capability[]?
---@return string error
function MemoryDriver:capabilities(emit_ch)
    if not self.initialised then
        return nil, "memory driver not initialised"
    end
    self.cap_emit_ch = emit_ch
    local cap, err = cap_types.new.MemoryCapability('1', self.control_ch)
    if not cap then
        return {}, err
    end
    return { cap }, ""
end

---@return boolean ok
---@return string error
function MemoryDriver:start()
    if not self.initialised then
        return false, "memory driver not initialised"
    end
    local payload, err = hal_types.new.Emit('memory', '1', 'meta', 'info', {
        provider = 'hal',
        version  = 1,
    })
    if payload and self.cap_emit_ch then
        self.cap_emit_ch:put(payload)
    elseif not payload then
        dlog(self.logger, 'debug', { what = 'meta_emit_failed', err = tostring(err) })
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
function MemoryDriver:stop(timeout)
    timeout = timeout or 5
    self.scope:cancel('memory driver stopped')
    local source = perform(op.named_choice {
        join    = self.scope:join_op(),
        timeout = sleep.sleep_op(timeout),
    })
    if source == 'timeout' then
        return false, "memory driver stop timeout"
    end
    return true, ""
end

---@param logger Logger?
---@return MemoryDriver?
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

    return setmetatable({
        scope       = scope,
        control_ch  = channel.new(CONTROL_Q_LEN),
        cap_emit_ch = nil,
        cache       = cache_mod.new(),
        logger      = logger,
        initialised = false,
    }, MemoryDriver), ""
end

return { new = new }
