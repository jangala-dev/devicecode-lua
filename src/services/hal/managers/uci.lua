local context = require "fibers.context"
local log = require "services.log"
local uci_driver = require "services.hal.drivers.uci"
local service = require "service"

local UCIManagement = {}
UCIManagement.__index = UCIManagement

local function new()
    local ubus_management = {}
    return setmetatable(ubus_management, UCIManagement)
end

function UCIManagement:_manager(ctx, conn, device_event_q, capability_info_q)
    log.trace(string.format(
        "%s - %s: Starting",
        ctx:value("service_name"),
        ctx:value("fiber_name")
    ))

    -- Check that uci package exists
    local uci = require "uci"

    if not uci then
        log.error(string.format(
            "%s - %s: uci package cannot be loaded",
            ctx:value("service_name"),
            ctx:value("fiber_name")
        ))
        return
    end

    local uci_instance = uci_driver.new(context.with_cancel(ctx))

    local capabilities, cap_err = uci_instance:apply_capabilities(capability_info_q)
    if cap_err then
        log.error(cap_err)
        return
    end

    uci_instance:spawn(conn)

    local device_event = {
        connected = true,
        type = 'uci',
        capabilities = capabilities,
        device_control = {},
        id_field = "id",
        data = {
            id = "uci"
        }
    }

    device_event_q:put(device_event)
end

function UCIManagement:spawn(ctx, conn, device_event_q, capability_info_q)
    service.spawn_fiber("UCI Manager", conn, ctx, function (fctx)
        self:_manager(fctx, conn, device_event_q, capability_info_q)
    end)
end

return { new = new }
