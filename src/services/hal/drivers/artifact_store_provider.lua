local fibers = require 'fibers'
local op = require 'fibers.op'
local sleep = require 'fibers.sleep'
local channel = require 'fibers.channel'

local hal_types = require 'services.hal.types.core'
local cap_types = require 'services.hal.types.capabilities'
local cap_args = require 'services.hal.types.capability_args'
local store_mod = require 'services.hal.drivers.artifact_store'

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
    if not st then return tostring(err or 'artifact_store_init_failed') end
    self.store = st
    self.initialised = true
    return ''
end

function Driver:create_sink(opts)
    if opts == nil or getmetatable(opts) ~= cap_args.ArtifactStoreCreateSinkOpts then return false, 'invalid opts' end
    local sink, err = self.store:create_sink(opts.meta, { policy = opts.policy })
    if not sink then return false, err end
    return true, sink
end

function Driver:import_path(opts)
    if opts == nil or getmetatable(opts) ~= cap_args.ArtifactStoreImportPathOpts then return false, 'invalid opts' end
    local art, err = self.store:import_path(opts.path, opts.meta, { policy = opts.policy })
    if not art then return false, err end
    return true, art
end

function Driver:import_source(opts)
    if opts == nil or getmetatable(opts) ~= cap_args.ArtifactStoreImportSourceOpts then return false, 'invalid opts' end
    local art, err = self.store:import_source(opts.source, opts.meta, { policy = opts.policy })
    if not art then return false, err end
    return true, art
end

function Driver:open(opts)
    if opts == nil or getmetatable(opts) ~= cap_args.ArtifactStoreOpenOpts then return false, 'invalid opts' end
    local art, err = self.store:open(opts.artifact_ref)
    if not art then return false, err end
    return true, art
end

function Driver:delete(opts)
    if opts == nil or getmetatable(opts) ~= cap_args.ArtifactStoreDeleteOpts then return false, 'invalid opts' end
    local ok, err = self.store:delete(opts.artifact_ref)
    if not ok then return false, err end
    return true, { ok = true }
end

function Driver:status(opts)
    if opts ~= nil and getmetatable(opts) ~= cap_args.ArtifactStoreStatusOpts then return false, 'invalid opts' end
    return true, self.store:status()
end

function Driver:capabilities(emit_ch)
    if not self.initialised then return nil, 'artifact_store provider not initialised' end
    self.cap_emit_ch = emit_ch
    local cap, err = cap_types.new.ArtifactStoreCapability(self.id, self.control_ch)
    if not cap then return nil, err end
    return { cap }, ''
end

function Driver:start()
    if not self.initialised then return false, 'artifact_store provider not initialised' end
    if self.cap_emit_ch then
        local meta, err = hal_types.new.Emit('artifact_store', self.id, 'meta', 'info', { provider = 'hal.artifact_store', version = 2 })
        if meta then self.cap_emit_ch:put(meta) else dlog(self.logger, 'debug', { what = 'artifact_store_meta_emit_failed', id = self.id, err = tostring(err) }) end
    end
    local methods = {
        create_sink = function(opts) return self:create_sink(opts) end,
        import_path = function(opts) return self:import_path(opts) end,
        import_source = function(opts) return self:import_source(opts) end,
        open = function(opts) return self:open(opts) end,
        delete = function(opts) return self:delete(opts) end,
        status = function(opts) return self:status(opts) end,
    }
    local ok, err = self.scope:spawn(function() run_control_loop(self.control_ch, methods, self.logger, 'artifact_store_control_manager') end)
    if not ok then return false, 'failed to spawn artifact_store control manager: ' .. tostring(err) end
    return true, ''
end

function Driver:stop(timeout)
    timeout = timeout or 5
    self.scope:cancel('artifact_store provider stopped')
    local source = fibers.perform(op.named_choice { join = self.scope:join_op(), timeout = sleep.sleep_op(timeout) })
    if source == 'timeout' then return false, 'artifact_store provider stop timeout' end
    return true, ''
end

local function new(id, opts, logger)
    if type(id) ~= 'string' or id == '' then return nil, 'invalid id' end
    local scope, err = fibers.current_scope():child()
    if not scope then return nil, 'failed to create child scope: ' .. tostring(err) end
    return setmetatable({ id = id, opts = opts or {}, logger = logger, scope = scope, store = nil, initialised = false, control_ch = channel.new(CONTROL_Q_LEN), cap_emit_ch = nil }, Driver), ''
end

return { new = new, Driver = Driver }
