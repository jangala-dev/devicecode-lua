-- services/hal/drivers/platform.lua
--
-- Narrow platform driver: exposes only platform identity / simple host facts.
-- Host-boundary capabilities such as artifact_store, control_store,
-- signature_verify and updater live in their own managers/drivers.

local fibers   = require 'fibers'
local op       = require 'fibers.op'
local sleep    = require 'fibers.sleep'
local file     = require 'fibers.io.file'
local exec     = require 'fibers.io.exec'
local cache_mod = require 'shared.cache'

local hal_types = require 'services.hal.types.core'
local cap_types = require 'services.hal.types.capabilities'
local cap_args  = require 'services.hal.types.capability_args'
local channel   = require 'fibers.channel'

local perform = fibers.perform
local CONTROL_Q_LEN = 8

local PlatformDriver = {}
PlatformDriver.__index = PlatformDriver

local function dlog(logger, level, payload)
    if logger and logger[level] then logger[level](logger, payload) end
end

local function read_file(path)
    local f, open_err = file.open(path, 'r')
    if not f then return nil, tostring(open_err) end
    local content, read_err = f:read_all()
    f:close()
    if not content then return nil, tostring(read_err) end
    return content, ''
end

local function trim(s)
    return (s or ''):match('^%s*(.-)%s*$') or ''
end

local function read_fw_printenv(varname)
    local cmd = exec.command('fw_printenv', varname)
    local out, _, code = perform(cmd:output_op())
    if code ~= 0 or not out then return '' end
    return trim(out:match(varname .. '=(.+)$') or '')
end

local function read_identity()
    local function safe_read(path)
        local v, _ = read_file(path)
        return trim(v or '')
    end

    return {
        hw_revision    = safe_read('/etc/hwrevision'),
        fw_version     = safe_read('/etc/fwversion'),
        serial         = safe_read('/data/serial'),
        board_revision = read_fw_printenv('board_revision'),
    }
end

local function run_control_loop(ch, methods, logger, what)
    fibers.current_scope():finally(function()
        dlog(logger, 'debug', { what = tostring(what or 'control_loop') .. '_exiting' })
    end)

    while true do
        local request, req_err = ch:get()
        if not request then
            dlog(logger, 'debug', { what = tostring(what or 'control_loop') .. '_closed', err = tostring(req_err) })
            break
        end

        local fn = methods[request.verb]
        local ok, value_or_err
        if type(fn) ~= 'function' then
            ok, value_or_err = false, 'unsupported verb: ' .. tostring(request.verb)
        else
            local st, _, r1, r2 = fibers.run_scope(function()
                return fn(request.opts)
            end)
            if st ~= 'ok' then
                ok, value_or_err = false, 'internal error: ' .. tostring(r1)
            else
                ok, value_or_err = r1, r2
            end
        end

        local reply = hal_types.new.Reply(ok, value_or_err)
        if reply then request.reply_ch:put(reply) end
    end
end

function PlatformDriver:init()
    if self.initialised then return 'already initialised' end
    self.initialised = true
    return ''
end

function PlatformDriver:platform_get(opts)
    if opts == nil or getmetatable(opts) ~= cap_args.PlatformGetOpts then
        return false, 'invalid opts'
    end

    if opts.field == 'identity' then
        return true, self.identity
    end

    if opts.field ~= 'uptime' then
        return false, 'unsupported field: ' .. tostring(opts.field)
    end

    local cached = self.cache:get('uptime', opts.max_age)
    if cached ~= nil then return true, cached end

    local raw, err = read_file('/proc/uptime')
    if not raw then return false, 'failed to read /proc/uptime: ' .. tostring(err) end
    local uptime_s = tonumber(raw:match('([%d%.]+)'))
    if not uptime_s then return false, 'failed to parse /proc/uptime' end

    self.cache:set('uptime', uptime_s)
    return true, uptime_s
end

function PlatformDriver:capabilities(emit_ch)
    if not self.initialised then return nil, 'platform driver not initialised' end
    self.cap_emit_ch = emit_ch

    local cap, err = cap_types.new.PlatformCapability('1', self.platform_ch)
    if not cap then return nil, err end
    return { cap }, ''
end

function PlatformDriver:start()
    if not self.initialised then return false, 'platform driver not initialised' end

    if self.cap_emit_ch then
        local state_payload, state_err = hal_types.new.Emit('platform', '1', 'state', 'identity', self.identity)
        if state_payload then self.cap_emit_ch:put(state_payload) else dlog(self.logger, 'debug', { what = 'platform_identity_emit_failed', err = tostring(state_err) }) end

        local meta_payload, meta_err = hal_types.new.Emit('platform', '1', 'meta', 'info', { provider = 'hal.platform', version = 3 })
        if meta_payload then self.cap_emit_ch:put(meta_payload) else dlog(self.logger, 'debug', { what = 'platform_meta_emit_failed', err = tostring(meta_err) }) end
    end

    local ok, err = self.scope:spawn(function()
        run_control_loop(self.platform_ch, { get = function(opts) return self:platform_get(opts) end }, self.logger, 'platform_control_manager')
    end)
    if not ok then return false, 'failed to spawn platform manager: ' .. tostring(err) end
    return true, ''
end

function PlatformDriver:stop(timeout)
    timeout = timeout or 5
    self.scope:cancel('platform driver stopped')
    local source = perform(op.named_choice {
        join = self.scope:join_op(),
        timeout = sleep.sleep_op(timeout),
    })
    if source == 'timeout' then return false, 'platform driver stop timeout' end
    return true, ''
end

local function new(logger)
    local scope, err = fibers.current_scope():child()
    if not scope then return nil, 'failed to create child scope: ' .. tostring(err) end

    scope:finally(function()
        local st, primary = scope:status()
        if st == 'failed' then dlog(logger, 'error', { what = 'scope_failed', err = tostring(primary), status = st }) end
        dlog(logger, 'debug', { what = 'stopped' })
    end)

    return setmetatable({
        scope = scope,
        logger = logger,
        cap_emit_ch = nil,
        initialised = false,
        identity = read_identity(),
        cache = cache_mod.new(),
        platform_ch = channel.new(CONTROL_Q_LEN),
    }, PlatformDriver), ''
end

return { new = new }
