-- services/hal/drivers/power.lua
--
-- Power HAL driver.
-- Exposes a 'power' capability with 'shutdown' and 'reboot' RPC offerings.
--
-- Reply-before-exec pattern: each verb spawns the exec in a child fiber and
-- returns true immediately so the control_manager sends the reply before the
-- OS executes the power command.

local fibers  = require "fibers"
local op      = require "fibers.op"
local sleep   = require "fibers.sleep"
local exec    = require "fibers.io.exec"
local channel = require "fibers.channel"

local hal_types = require "services.hal.types.core"
local cap_types      = require "services.hal.types.capabilities"
local external_types = require "services.hal.types.external"
local log            = require "services.log"

local perform = fibers.perform

local CONTROL_Q_LEN = 8

-- Delay (seconds) before executing a power command.  This gives the reply
-- time to be transmitted to the caller before the system goes down.
local EXEC_DELAY = 1

---@class PowerDriver
---@field scope Scope
---@field control_ch Channel
---@field cap_emit_ch Channel?
local PowerDriver = {}
PowerDriver.__index = PowerDriver

---- capability verbs ----

---@param opts PowerActionOpts?
---@return boolean ok
---@return nil reason
function PowerDriver:shutdown(opts)
    if opts ~= nil and getmetatable(opts) ~= external_types.PowerActionOpts then
        return false, "invalid opts"
    end
    local delay = (opts and opts.delay) or EXEC_DELAY
    self.scope:spawn(function()
        -- Give caller time to receive the reply before the system shuts down.
        perform(sleep.sleep_op(delay))
        log.info("Power Driver: executing shutdown")
        local cmd = exec.command('shutdown', '-h', 'now')
        perform(cmd:run_op())
    end)
    return true, nil
end

---@param opts PowerActionOpts?
---@return boolean ok
---@return nil reason
function PowerDriver:reboot(opts)
    if opts ~= nil and getmetatable(opts) ~= external_types.PowerActionOpts then
        return false, "invalid opts"
    end
    local delay = (opts and opts.delay) or EXEC_DELAY
    self.scope:spawn(function()
        perform(sleep.sleep_op(delay))
        log.info("Power Driver: executing reboot")
        local cmd = exec.command('reboot')
        perform(cmd:run_op())
    end)
    return true, nil
end

---- control manager ----

function PowerDriver:control_manager()
    fibers.current_scope():finally(function()
        log.trace("Power Driver: control_manager exiting")
    end)

    while true do
        local request, req_err = self.control_ch:get()
        if not request then
            log.debug("Power Driver: control_ch closed:", req_err)
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

        -- Reply is sent BEFORE the exec fiber (spawned by shutdown/reboot) runs.
        local reply = hal_types.new.Reply(ok, value_or_err)
        if reply then
            request.reply_ch:put(reply)
        end
    end
end

---- public interface ----

---@return string error
function PowerDriver:init()
    if self.initialised then
        return "already initialised"
    end
    self.initialised = true
    return ""
end

---@param emit_ch Channel
---@return Capability[]?
---@return string error
function PowerDriver:capabilities(emit_ch)
    if not self.initialised then
        return nil, "power driver not initialised"
    end
    self.cap_emit_ch = emit_ch
    local cap, err = cap_types.new.PowerCapability('1', self.control_ch)
    if not cap then
        return {}, err
    end
    return { cap }, ""
end

---@return boolean ok
---@return string error
function PowerDriver:start()
    if not self.initialised then
        return false, "power driver not initialised"
    end
    if self.cap_emit_ch then
        local meta_payload, meta_err = hal_types.new.Emit('power', '1', 'meta', 'info', {
            provider = 'hal',
            version  = 1,
        })
        if meta_payload then
            self.cap_emit_ch:put(meta_payload)
        else
            log.debug("Power Driver: meta emit failed:", meta_err)
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
function PowerDriver:stop(timeout)
    timeout = timeout or 5
    self.scope:cancel('power driver stopped')
    local source = perform(op.named_choice {
        join    = self.scope:join_op(),
        timeout = sleep.sleep_op(timeout),
    })
    if source == 'timeout' then
        return false, "power driver stop timeout"
    end
    return true, ""
end

---@return PowerDriver?
---@return string error
local function new()
    local scope, err = fibers.current_scope():child()
    if not scope then
        return nil, "failed to create child scope: " .. tostring(err)
    end

    scope:finally(function()
        local st, primary = scope:status()
        if st == 'failed' then
            log.error(("Power Driver: error - %s"):format(tostring(primary)))
        end
        log.trace("Power Driver: stopped")
    end)

    return setmetatable({
        scope       = scope,
        control_ch  = channel.new(CONTROL_Q_LEN),
        cap_emit_ch = nil,
        initialised = false,
    }, PowerDriver), ""
end

return { new = new }
