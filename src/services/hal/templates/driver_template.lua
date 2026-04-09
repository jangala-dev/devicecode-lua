local hal_types = require "services.hal.types.core"
local cap_types = require "services.hal.types.capabilities"

local fibers = require "fibers"
local op = require "fibers.op"
local channel = require "fibers.channel"
local sleep = require "fibers.sleep"

---@class TemplateDriver
---@field id string
---@field scope Scope
---@field control_ch Channel
---@field cap_emit_ch Channel?
---@field initialised boolean
---@field caps_applied boolean
---@field log Logger
local TemplateDriver = {}
TemplateDriver.__index = TemplateDriver

local CONTROL_Q_LEN = 8
local DEFAULT_STOP_TIMEOUT = 5

local function return_error(err, code)
    if err == nil then
        err = "unknown error"
    end
    return false, err, code
end

local function emit(emit_ch, class, id, mode, key, data)
    local payload, err = hal_types.new.Emit(class, id, mode, key, data)
    if not payload then
        return false, err
    end
    emit_ch:put(payload)
    return true, ""
end

---@param fn any
---@return boolean ok
---@return string? error
local function validate_fn(fn)
    if type(fn) ~= "function" then
        return false, "verb handler is unimplemented"
    end
    return true, nil
end

function TemplateDriver:init()
    self.initialised = true
    return ""
end

---@param opts table<string, any>?
---@return boolean ok
---@return any reason_or_value
---@return integer? code
function TemplateDriver:get_status(opts)
    if opts ~= nil and type(opts) ~= "table" then
        return return_error("invalid options", 1)
    end
    local snapshot = {
        id = self.id,
        state = "ready",
    }
    return true, snapshot
end

---@param opts table<string, any>?
---@return boolean ok
---@return string? reason
---@return integer? code
function TemplateDriver:reset(opts)
    if opts ~= nil and type(opts) ~= "table" then
        return return_error("invalid options", 1)
    end
    if self.cap_emit_ch then
        emit(self.cap_emit_ch, "template", self.id, "event", "reset", { at = os.time() })
    end
    return true
end

function TemplateDriver:control_manager()
    fibers.current_scope():finally(function()
        self.log:debug({ what = "template_driver_control_manager_stopped", id = self.id })
    end)

    while true do
        local request, err = fibers.perform(self.control_ch:get_op())
        if not request then
            self.log:error({ what = "control_channel_read_failed", id = self.id, err = tostring(err) })
            return
        end

        local fn = self[request.verb]
        local valid, validation_err = validate_fn(fn)

        local ok, reason, code
        if not valid then
            ok, reason, code = false, validation_err, 1
        else
            local call_ok, fn_ok, fn_reason, fn_code = pcall(fn, self, request.opts)
            if not call_ok then
                ok, reason, code = false, tostring(fn_ok), 1
            else
                ok, reason, code = fn_ok, fn_reason, fn_code
            end
        end

        local reply, reply_err = hal_types.new.Reply(ok, reason, code)
        if not reply then
            self.log:error({ what = "reply_create_failed", id = self.id, err = tostring(reply_err) })
        else
            request.reply_ch:put(reply)
        end
    end
end

---@return boolean ok
---@return string error
function TemplateDriver:start()
    if not self.initialised then
        return false, "driver not initialised"
    end
    if not self.caps_applied then
        return false, "capabilities not applied"
    end

    self.scope:spawn(function()
        self:control_manager()
    end)

    return true, ""
end

---@param timeout number?
---@return boolean ok
---@return string error
function TemplateDriver:stop(timeout)
    timeout = timeout or DEFAULT_STOP_TIMEOUT
    self.scope:cancel()

    local source = fibers.perform(op.named_choice {
        join = self.scope:join_op(),
        timeout = sleep.sleep_op(timeout),
    })

    if source == "timeout" then
        return false, "template driver stop timeout"
    end
    return true, ""
end

---@param emit_ch Channel
---@return Capability[]? capabilities
---@return string error
function TemplateDriver:capabilities(emit_ch)
    if not self.initialised then
        return nil, "driver not initialised"
    end
    if self.caps_applied then
        return nil, "capabilities already applied"
    end

    self.cap_emit_ch = emit_ch

    local cap, cap_err = cap_types.new.Capability(
        "template",
        self.id,
        self.control_ch,
        { "get_status", "reset" }
    )
    if not cap then
        return nil, cap_err
    end

    self.caps_applied = true
    return { cap }, ""
end

---@param id string
---@param logger Logger
---@return TemplateDriver? driver
---@return string error
local function new(id, logger)
    if type(id) ~= "string" or id == "" then
        return nil, "invalid id"
    end

    local scope, err = fibers.current_scope():child()
    if not scope then
        return nil, "failed to create child scope: " .. tostring(err)
    end

    local driver = setmetatable({
        id = id,
        scope = scope,
        control_ch = channel.new(CONTROL_Q_LEN),
        cap_emit_ch = nil,
        initialised = false,
        caps_applied = false,
        log = logger,
    }, TemplateDriver)

    return driver, ""
end

return {
    new = new,
    Driver = TemplateDriver,
}
