local exec = require "fibers.exec"
local context = require "fibers.context"
local log = require "services.log"
local ubus_driver = require "services.hal.drivers.ubus"
local service = require "service"

local UBusManagement = {}
UBusManagement.__index = UBusManagement

local function new()
    local ubus_management = {}
    return setmetatable(ubus_management, UBusManagement)
end

function UBusManagement:_manager(ctx, conn, device_event_q, capability_info_q)
    log.trace(string.format(
        "%s - %s: Starting",
        ctx:value("service_name"),
        ctx:value("fiber_name")
    ))

    -- Check that ubus command responds
    local _, err = exec.command_context(ctx, 'ubus', '-v'):output()

    if err and err ~= 1 then
        log.error(string.format(
            "%s - %s: ubus driver cannot be started, reason: %s",
            ctx:value("service_name"),
            ctx:value("fiber_name"),
            err
        ))
        return
    end

    local ubus_instance = ubus_driver.new(context.with_cancel(ctx))

    local capabilities, cap_err = ubus_instance:apply_capabilities(capability_info_q)
    if cap_err then
        log.error(cap_err)
        return
    end

    ubus_instance:spawn(conn)

    local device_event = {
        connected = true,
        type = 'bus',
        capabilities = capabilities,
        device_control = {},
        id_field = "id",
        data = {
            id = "ubus"
        }
    }

    device_event_q:put(device_event)
end

function UBusManagement:spawn(ctx, conn, device_event_q, capability_info_q)
    service.spawn_fiber("UBus Manager", conn, ctx, function (fctx)
        self:_manager(fctx, conn, device_event_q, capability_info_q)
    end)
end

return { new = new }
