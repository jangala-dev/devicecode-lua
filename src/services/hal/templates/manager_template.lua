-- services/hal/templates/manager_template.lua
--
-- Strict HAL manager template.
--
-- New managers advertise api_mode = 'op_only'. HAL will call start_op(),
-- apply_config_op(), shutdown_op(), terminate(reason), and fault_op(). Legacy stop/stop_op
-- belong only on the compatibility side of hal.lua.

local hal_types = require "services.hal.types.core"
local driver_template = require "services.hal.templates.driver_template"
local resource = require "devicecode.support.resource"

local fibers = require "fibers"
local op = require "fibers.op"
local channel = require "fibers.channel"
local sleep = require "fibers.sleep"

---@class TemplateManager
---@field api_mode string
---@field scope Scope|nil
---@field started boolean
---@field detect_ch Channel
---@field remove_ch Channel
---@field ready_driver_ch Channel
---@field drivers table<string, TemplateDriver>
---@field log Logger|nil
local TemplateManager = {
    api_mode = 'op_only',
    scope = nil,
    started = false,
    detect_ch = channel.new(),
    remove_ch = channel.new(),
    ready_driver_ch = channel.new(),
    drivers = {},
    log = nil,
}

local DEFAULT_SHUTDOWN_TIMEOUT = 5.0

local function detector(scope)
    scope:finally(function ()
        TemplateManager.log:debug({ what = "template_detector_stopped" })
    end)

    while true do
        local which, payload = fibers.perform(fibers.named_choice{
            detect = TemplateManager.detect_ch:get_op(),
            remove = TemplateManager.remove_ch:get_op(),
        })

        if which == "detect" then
            local id = payload
            local driver, err = driver_template.new(id, TemplateManager.log:child({ template = id }))
            if not driver then
                TemplateManager.log:error({ what = "template_driver_create_failed", id = id, err = tostring(err) })
            else
                local ok, spawn_err = fibers.spawn(function ()
                    local ok_init, init_err = fibers.perform(driver:init_op())
                    if not ok_init then
                        TemplateManager.log:error({ what = "template_driver_init_failed", id = id, err = tostring(init_err) })
                        return
                    end
                    fibers.perform(TemplateManager.ready_driver_ch:put_op(driver))
                end)
                if not ok then
                    resource.terminate_checked(driver, tostring(spawn_err or "driver init spawn failed"), "template driver init cleanup failed")
                end
            end
        elseif which == "remove" then
            local id = payload
            local driver = TemplateManager.drivers[id]
            if driver then
                TemplateManager.drivers[id] = nil
                local ok, err = fibers.perform(driver:shutdown_op(DEFAULT_SHUTDOWN_TIMEOUT))
                if not ok then
                    resource.terminate_checked(driver, tostring(err or "driver shutdown failed"), "template driver shutdown cleanup failed")
                end
            end
        end
    end
end

local function manager_loop(scope, dev_ev_ch, cap_emit_ch)
    scope:finally(function ()
        TemplateManager.log:debug({ what = "template_manager_loop_stopped" })
    end)

    while true do
        local driver = fibers.perform(TemplateManager.ready_driver_ch:get_op())
        if not driver then
            return
        end

        repeat
            local ok_caps, caps_or_err = fibers.perform(driver:capabilities_op(cap_emit_ch))
            if not ok_caps then
                TemplateManager.log:error({ what = "template_caps_failed", err = tostring(caps_or_err) })
                resource.terminate_checked(driver, "capabilities failed", "template driver capabilities cleanup failed")
                break
            end

            local ok_start, start_err = fibers.perform(driver:start_op(scope))
            if not ok_start then
                TemplateManager.log:error({ what = "template_start_failed", err = tostring(start_err) })
                resource.terminate_checked(driver, "start failed", "template driver start cleanup failed")
                break
            end

            TemplateManager.drivers[driver.id] = driver

            local ev, ev_err = hal_types.new.DeviceEvent(
                "added",
                "template_device",
                driver.id,
                { source = "template" },
                caps_or_err
            )
            if not ev then
                TemplateManager.log:error({ what = "template_device_event_failed", err = tostring(ev_err) })
                break
            end

            fibers.perform(dev_ev_ch:put_op(ev))
        until true
    end
end

function TemplateManager.start_op(logger, dev_ev_ch, cap_emit_ch)
    return op.guard(function ()
        if TemplateManager.started then
            return op.always(false, "already started")
        end

        local owner_scope = fibers.current_scope()
        local scope, err = owner_scope:child()
        if not scope then
            return op.always(false, tostring(err))
        end

        TemplateManager.log = logger
        TemplateManager.scope = scope

        scope:finally(function ()
            TemplateManager.terminate("template manager scope finalised")
        end)

        local ok1, err1 = scope:spawn(detector)
        if not ok1 then
            TemplateManager.terminate(tostring(err1 or "detector spawn failed"))
            return op.always(false, tostring(err1))
        end

        local ok2, err2 = scope:spawn(manager_loop, dev_ev_ch, cap_emit_ch)
        if not ok2 then
            TemplateManager.terminate(tostring(err2 or "manager loop spawn failed"))
            return op.always(false, tostring(err2))
        end

        TemplateManager.started = true
        return op.always(true, nil)
    end)
end

function TemplateManager.shutdown_op(timeout)
    timeout = timeout or DEFAULT_SHUTDOWN_TIMEOUT

    return op.guard(function ()
        local scope = TemplateManager.scope
        if not TemplateManager.started or not scope then
            return op.always(true, nil)
        end

        scope:cancel("template manager shutdown")

        return fibers.boolean_choice(
            scope:join_op():wrap(function ()
                TemplateManager.terminate("template manager joined")
                return true, nil
            end),
            sleep.sleep_op(timeout):wrap(function ()
                return false, "template manager shutdown timeout"
            end)
        ):wrap(function (completed, _a, b)
            if completed then return true, nil end
            return false, b
        end)
    end)
end

function TemplateManager.terminate(reason)
    for id, driver in pairs(TemplateManager.drivers or {}) do
        resource.terminate_checked(driver, reason or "template manager terminated", "template manager driver cleanup failed")
        TemplateManager.drivers[id] = nil
    end

    if TemplateManager.scope then
        TemplateManager.scope:cancel(reason or "template manager terminated")
    end

    TemplateManager.scope = nil
    TemplateManager.started = false
    return true, nil
end

function TemplateManager.fault_op()
    if TemplateManager.scope and TemplateManager.started then
        return TemplateManager.scope:fault_op()
    end
    return op.never()
end

function TemplateManager.apply_config_op(_namespaces)
    return op.always(true, nil)
end

return TemplateManager
