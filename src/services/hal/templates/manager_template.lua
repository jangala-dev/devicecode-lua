local hal_types = require "services.hal.types.core"
local driver_template = require "services.hal.templates.driver_template"

local fibers = require "fibers"
local op = require "fibers.op"
local channel = require "fibers.channel"
local sleep = require "fibers.sleep"

---@class TemplateManager
---@field scope Scope?
---@field started boolean
---@field detect_ch Channel
---@field remove_ch Channel
---@field ready_driver_ch Channel
---@field drivers table<string, TemplateDriver>
---@field log Logger?
local TemplateManager = {
    scope = nil,
    started = false,
    detect_ch = channel.new(),
    remove_ch = channel.new(),
    ready_driver_ch = channel.new(),
    drivers = {},
    log = nil,
}

local STOP_TIMEOUT = 5

-- Example detector: in a real manager this is backed by udev/mmcli/ubus/config watcher.
local function detector(scope)
    scope:finally(function()
        TemplateManager.log:debug({ what = "template_detector_stopped" })
    end)

    while true do
        local source, payload = fibers.perform(op.named_choice {
            detect = TemplateManager.detect_ch:get_op(),
            remove = TemplateManager.remove_ch:get_op(),
        })

        if source == "detect" then
            local id = payload
            local driver, err = driver_template.new(id, TemplateManager.log:child({ template = id }))
            if not driver then
                TemplateManager.log:error({ what = "template_driver_create_failed", id = id, err = tostring(err) })
            else
                fibers.current_scope():spawn(function()
                    local init_err = driver:init()
                    if init_err ~= "" then
                        TemplateManager.log:error({ what = "template_driver_init_failed", id = id, err = init_err })
                        return
                    end
                    TemplateManager.ready_driver_ch:put(driver)
                end)
            end
        elseif source == "remove" then
            local id = payload
            local driver = TemplateManager.drivers[id]
            if driver then
                fibers.current_scope():spawn(function()
                    driver:stop(STOP_TIMEOUT)
                end)
                TemplateManager.drivers[id] = nil
            end
        end
    end
end

local function manager(scope, dev_ev_ch, cap_emit_ch)
    scope:finally(function()
        TemplateManager.log:debug({ what = "template_manager_loop_stopped" })
    end)

    while true do
        local driver = fibers.perform(TemplateManager.ready_driver_ch:get_op())
        if not driver then
            return
        end

        local caps, cap_err = driver:capabilities(cap_emit_ch)
        if cap_err ~= "" then
            TemplateManager.log:error({ what = "template_caps_failed", err = cap_err })
            goto continue
        end

        local ok, start_err = driver:start()
        if not ok then
            TemplateManager.log:error({ what = "template_start_failed", err = tostring(start_err) })
            goto continue
        end

        TemplateManager.drivers[driver.id] = driver

        local ev, ev_err = hal_types.new.DeviceEvent(
            "added",
            "template_device",
            driver.id,
            { source = "template" },
            caps
        )
        if not ev then
            TemplateManager.log:error({ what = "template_device_event_failed", err = tostring(ev_err) })
            goto continue
        end

        dev_ev_ch:put(ev)

        ::continue::
    end
end

---@param logger Logger
---@param dev_ev_ch Channel
---@param cap_emit_ch Channel
---@return string error
function TemplateManager.start(logger, dev_ev_ch, cap_emit_ch)
    if TemplateManager.started then
        return "Already started"
    end

    local scope, err = fibers.current_scope():child()
    if not scope then
        return "Failed to create child scope: " .. tostring(err)
    end

    TemplateManager.log = logger
    TemplateManager.scope = scope

    scope:spawn(detector)
    scope:spawn(manager, dev_ev_ch, cap_emit_ch)

    TemplateManager.started = true
    return ""
end

---@param timeout number?
---@return boolean ok
---@return string error
function TemplateManager.stop(timeout)
    if not TemplateManager.started or not TemplateManager.scope then
        return false, "Not started"
    end

    timeout = timeout or STOP_TIMEOUT
    TemplateManager.scope:cancel()

    local source = fibers.perform(op.named_choice {
        join = TemplateManager.scope:join_op(),
        timeout = sleep.sleep_op(timeout),
    })

    if source == "timeout" then
        return false, "template manager stop timeout"
    end

    TemplateManager.started = false
    return true, ""
end

-- Managers must expose apply_config even if they do not use runtime config.
---@param namespaces table
---@return boolean ok
---@return string error
function TemplateManager.apply_config(namespaces) -- luacheck: ignore
    return true, ""
end

return TemplateManager
