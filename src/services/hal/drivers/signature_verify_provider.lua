local fibers = require 'fibers'
local op = require 'fibers.op'
local sleep = require 'fibers.sleep'
local channel = require 'fibers.channel'

local hal_types = require 'services.hal.types.core'
local cap_types = require 'services.hal.types.capabilities'
local cap_args = require 'services.hal.types.capability_args'
local openssl = require 'services.hal.drivers.signature_verify_openssl'

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
    self.verifier = openssl.new(self.opts or {})
    self.initialised = true
    return ''
end

function Driver:verify_ed25519(opts)
    if opts == nil or getmetatable(opts) ~= cap_args.SignatureVerifyEd25519Opts then return false, 'invalid opts' end
    return self.verifier:verify_ed25519(opts.pubkey_pem, opts.message, opts.signature)
end

function Driver:capabilities(emit_ch)
    if not self.initialised then return nil, 'signature_verify provider not initialised' end
    self.cap_emit_ch = emit_ch
    local cap, err = cap_types.new.SignatureVerifyCapability(self.id, self.control_ch)
    if not cap then return nil, err end
    return { cap }, ''
end

function Driver:start()
    if not self.initialised then return false, 'signature_verify provider not initialised' end
    if self.cap_emit_ch then
        local meta, err = hal_types.new.Emit('signature_verify', self.id, 'meta', 'info', { provider = 'hal.signature_verify', backend = 'openssl-cli', version = 2 })
        if meta then self.cap_emit_ch:put(meta) else dlog(self.logger, 'debug', { what = 'signature_verify_meta_emit_failed', id = self.id, err = tostring(err) }) end
    end
    local methods = { verify_ed25519 = function(opts) return self:verify_ed25519(opts) end }
    local ok, err = self.scope:spawn(function() run_control_loop(self.control_ch, methods, self.logger, 'signature_verify_control_manager') end)
    if not ok then return false, 'failed to spawn signature_verify control manager: ' .. tostring(err) end
    return true, ''
end

function Driver:stop(timeout)
    timeout = timeout or 5
    self.scope:cancel('signature_verify provider stopped')
    local source = fibers.perform(op.named_choice { join = self.scope:join_op(), timeout = sleep.sleep_op(timeout) })
    if source == 'timeout' then return false, 'signature_verify provider stop timeout' end
    return true, ''
end

local function new(id, opts, logger)
    if type(id) ~= 'string' or id == '' then return nil, 'invalid id' end
    local scope, err = fibers.current_scope():child()
    if not scope then return nil, 'failed to create child scope: ' .. tostring(err) end
    return setmetatable({ id = id, opts = opts or {}, logger = logger, scope = scope, verifier = nil, initialised = false, control_ch = channel.new(CONTROL_Q_LEN), cap_emit_ch = nil }, Driver), ''
end

return { new = new, Driver = Driver }
