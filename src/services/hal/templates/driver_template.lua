-- services/hal/templates/driver_template.lua
--
-- Strict HAL driver template.
--
-- New drivers should expose Op-returning operations, graceful component
-- shutdown through shutdown_op(), and immediate finaliser-safe cleanup through
-- terminate(reason).  Ordinary resources owned by a driver should use
-- close_op() for graceful close and terminate(reason) for finaliser cleanup.

local hal_types = require "services.hal.types.core"
local cap_types = require "services.hal.types.capabilities"

local fibers = require "fibers"
local op = require "fibers.op"
local channel = require "fibers.channel"
local sleep = require "fibers.sleep"
local safe = require "coxpcall"

---@class TemplateDriver
---@field id string
---@field scope Scope|nil
---@field control_ch Channel
---@field cap_emit_ch Channel|nil
---@field initialised boolean
---@field caps_applied boolean
---@field started boolean
---@field log Logger
local TemplateDriver = {}
TemplateDriver.__index = TemplateDriver

local CONTROL_Q_LEN = 8
local DEFAULT_SHUTDOWN_TIMEOUT = 5.0

local function return_error(err, code)
    return false, err or "unknown error", code
end

local function emit_op(emit_ch, class, id, mode, key, data)
    return op.guard(function ()
        local payload, err = hal_types.new.Emit(class, id, mode, key, data)
        if not payload then
            return op.always(false, err)
        end

        return emit_ch:put_op(payload):wrap(function (sent, send_err)
            if sent ~= false and sent ~= nil then
                return true, nil
            end
            return false, tostring(send_err or "emit channel closed")
        end)
    end)
end

local function validate_fn(fn)
    if type(fn) ~= "function" then
        return false, "verb handler is unimplemented"
    end
    return true, nil
end

function TemplateDriver:init_op()
    return op.guard(function ()
        self.initialised = true
        return op.always(true, nil)
    end)
end

function TemplateDriver:get_status_op(opts)
    return op.guard(function ()
        if opts ~= nil and type(opts) ~= "table" then
            return op.always(return_error("invalid options", 1))
        end

        return op.always(true, {
            id = self.id,
            state = "ready",
        })
    end)
end

function TemplateDriver:reset_op(opts)
    return op.guard(function ()
        if opts ~= nil and type(opts) ~= "table" then
            return op.always(return_error("invalid options", 1))
        end

        if self.cap_emit_ch then
            return emit_op(self.cap_emit_ch, "template", self.id, "event", "reset", {
                at = os.time(),
            })
        end

        return op.always(true, nil)
    end)
end

local function control_loop(self, scope)
    scope:finally(function ()
        self.log:debug({ what = "template_driver_control_loop_stopped", id = self.id })
    end)

    while true do
        local request, b = fibers.perform(self.control_ch:get_op())
        if not request then
            self.log:error({ what = "control_channel_read_failed", id = self.id, err = tostring(b) })
            return
        end

        local fn = self[request.verb .. "_op"]
        local valid, validation_err = validate_fn(fn)

        local ok, reason, code
        if not valid then
            ok, reason, code = false, validation_err, 1
        else
            local call_ok, fn_ok, fn_reason, fn_code = safe.pcall(function ()
                return fibers.perform(fn(self, request.opts))
            end)

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
            local sent, send_err = fibers.perform(request.reply_ch:put_op(reply))
            if sent == false or sent == nil then
                self.log:error({ what = "reply_send_failed", id = self.id, err = tostring(send_err) })
            end
        end
    end
end

function TemplateDriver:start_op(owner_scope)
    return op.guard(function ()
        if self.started then
            return op.always(false, "already started")
        end
        if not self.initialised then
            return op.always(false, "driver not initialised")
        end
        if not self.caps_applied then
            return op.always(false, "capabilities not applied")
        end

        local scope, err = owner_scope:child()
        if not scope then
            return op.always(false, tostring(err))
        end

        self.scope = scope

        local ok, spawn_err = scope:spawn(function ()
            return control_loop(self, scope)
        end)
        if not ok then
            self.scope = nil
            scope:cancel(tostring(spawn_err or "template driver spawn failed"))
            return op.always(false, tostring(spawn_err))
        end

        self.started = true
        return op.always(true, nil)
    end)
end

function TemplateDriver:shutdown_op(timeout)
    timeout = timeout or DEFAULT_SHUTDOWN_TIMEOUT

    return op.guard(function ()
        local scope = self.scope
        if not self.started or not scope then
            return op.always(true, nil)
        end

        scope:cancel("template driver shutdown")

        return fibers.boolean_choice(
            scope:join_op():wrap(function ()
                self.started = false
                self.scope = nil
                return true, nil
            end),
            sleep.sleep_op(timeout):wrap(function ()
                return false, "template driver shutdown timeout"
            end)
        ):wrap(function (completed, _a, b)
            if completed then return true, nil end
            return false, b
        end)
    end)
end

function TemplateDriver:terminate(reason)
    if self.scope then
        self.scope:cancel(reason or "template driver terminated")
    end
    self.started = false
    self.scope = nil
    return true, nil
end

function TemplateDriver:capabilities_op(emit_ch)
    return op.guard(function ()
        if not self.initialised then
            return op.always(false, "driver not initialised")
        end
        if self.caps_applied then
            return op.always(false, "capabilities already applied")
        end

        self.cap_emit_ch = emit_ch

        local cap, cap_err = cap_types.new.Capability(
            "template",
            self.id,
            self.control_ch,
            { "get_status", "reset" }
        )
        if not cap then
            return op.always(false, cap_err)
        end

        self.caps_applied = true
        return op.always(true, { cap })
    end)
end

local function new(id, logger)
    if type(id) ~= "string" or id == "" then
        return nil, "invalid id"
    end

    return setmetatable({
        id = id,
        scope = nil,
        control_ch = channel.new(CONTROL_Q_LEN),
        cap_emit_ch = nil,
        initialised = false,
        caps_applied = false,
        started = false,
        log = logger,
    }, TemplateDriver), nil
end

return {
    new = new,
    Driver = TemplateDriver,
}
