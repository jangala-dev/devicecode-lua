local fibers = require 'fibers'
local op = require 'fibers.op'
local sleep = require 'fibers.sleep'
local channel = require 'fibers.channel'

local hal_types = require 'services.hal.types.core'
local cap_types = require 'services.hal.types.capabilities'
local cap_args = require 'services.hal.types.capability_args'
local store_mod = require 'services.hal.drivers.control_store'

local CONTROL_Q_LEN = 8
local Driver = {}
Driver.__index = Driver

local function dlog(logger, level, payload)
    if logger and logger[level] then logger[level](logger, payload) end
end

local function run_control_loop(ch, methods, logger, what)
    fibers.current_scope():finally(function() dlog(logger, 'debug', { what = tostring(what or 'control_loop') .. '_exiting' }) end)
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
            local st, _, r1, r2 = fibers.run_scope(function() return fn(request.opts) end)
            if st ~= 'ok' then ok, value_or_err = false, 'internal error: ' .. tostring(r1) else ok, value_or_err = r1, r2 end
        end
        local reply = hal_types.new.Reply(ok, value_or_err)
        if reply then request.reply_ch:put(reply) end
    end
end

function Driver:init()
    if self.initialised then return 'already initialised' end
    local st, err = store_mod.new(self.opts or {}, self.logger)
    if not st then return tostring(err or 'control_store_init_failed') end
    self.store = st
    self.initialised = true
    return ''
end

function Driver:get(opts)
    if opts == nil or getmetatable(opts) ~= cap_args.ControlStoreGetOpts then return false, 'invalid opts' end
    local value, err = self.store:get(opts.ns, opts.key)
    if value == nil then return false, err end
    return true, value
end

function Driver:put(opts)
    if opts == nil or getmetatable(opts) ~= cap_args.ControlStorePutOpts then return false, 'invalid opts' end
    local ok, err = self.store:put(opts.ns, opts.key, opts.value)
    if not ok then return false, err end
    return true, { ok = true }
end

function Driver:delete(opts)
    if opts == nil or getmetatable(opts) ~= cap_args.ControlStoreDeleteOpts then return false, 'invalid opts' end
    local ok, err = self.store:delete(opts.ns, opts.key)
    if not ok then return false, err end
    return true, { ok = true }
end

function Driver:list(opts)
    if opts == nil or getmetatable(opts) ~= cap_args.ControlStoreListOpts then return false, 'invalid opts' end
    local keys, err = self.store:list(opts.ns)
    if not keys then return false, err end
    return true, { ns = opts.ns, keys = keys }
end

function Driver:status(opts)
    if opts ~= nil and getmetatable(opts) ~= cap_args.ControlStoreStatusOpts then return false, 'invalid opts' end
    return true, self.store:status()
end

function Driver:capabilities(emit_ch)
    if not self.initialised then return nil, 'control_store provider not initialised' end
    self.cap_emit_ch = emit_ch
    local cap, err = cap_types.new.ControlStoreCapability(self.id, self.control_ch)
    if not cap then return nil, err end
    return { cap }, ''
end

function Driver:start()
    if not self.initialised then return false, 'control_store provider not initialised' end
    if self.cap_emit_ch then
        local meta, err = hal_types.new.Emit('control_store', self.id, 'meta', 'info', { provider = 'hal.control_store', version = 2 })
        if meta then self.cap_emit_ch:put(meta) else dlog(self.logger, 'debug', { what = 'control_store_meta_emit_failed', id = self.id, err = tostring(err) }) end
    end
    local methods = {
        get = function(opts) return self:get(opts) end,
        put = function(opts) return self:put(opts) end,
        delete = function(opts) return self:delete(opts) end,
        list = function(opts) return self:list(opts) end,
        status = function(opts) return self:status(opts) end,
    }
    local ok, err = self.scope:spawn(function() run_control_loop(self.control_ch, methods, self.logger, 'control_store_control_manager') end)
    if not ok then return false, 'failed to spawn control_store control manager: ' .. tostring(err) end
    return true, ''
end

function Driver:stop(timeout)
    timeout = timeout or 5
    self.scope:cancel('control_store provider stopped')
    local source = fibers.perform(op.named_choice { join = self.scope:join_op(), timeout = sleep.sleep_op(timeout) })
    if source == 'timeout' then return false, 'control_store provider stop timeout' end
    return true, ''
end

local function new(id, opts, logger)
    if type(id) ~= 'string' or id == '' then return nil, 'invalid id' end
    local scope, err = fibers.current_scope():child()
    if not scope then return nil, 'failed to create child scope: ' .. tostring(err) end
    return setmetatable({ id = id, opts = opts or {}, logger = logger, scope = scope, store = nil, initialised = false, control_ch = channel.new(CONTROL_Q_LEN), cap_emit_ch = nil }, Driver), ''
end

return { new = new, Driver = Driver }
