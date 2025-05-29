local context = require "fibers.context"
local fiber = require 'fibers.fiber'
local bus = require "bus"
local new_msg = bus.new_msg
local log = require 'services.log'

local STATE = {
    INITIALISING = 'initialising',
    ACTIVE = 'active',
    DISABLED = 'disabled'
}
local FiberRegister = {}
FiberRegister.__index = FiberRegister

function FiberRegister.new()
    return setmetatable({size = 0, fibers = {}}, FiberRegister)
end

function FiberRegister:add(name, status)
    if self.fibers[name] == nil then
        self.size = self.size + 1
    end
    self.fibers[name] = status
end

function FiberRegister:remove(name)
    if self.fibers[name] ~= nil then
        self.size = self.size - 1
        self.fibers[name] = nil
    end
end

function FiberRegister:is_empty()
    return self.size == 0
end

-- spawns a service, which involves creation of a child context,
-- bus connection and a shutdown fiber
-- (which should be adapted for update, reboot etc when system service is more built out)
local function spawn(service, bus, ctx)
    local bus_connection = bus:connect()
    local cancel_ctx, cancel_fn = context.with_cancel(ctx)
    if service.name == nil then
        log.error("Service name is nil")
        return
    end
    local child_ctx = context.with_value(cancel_ctx, "service_name", service.name)

    local health_topic = { child_ctx:value("service_name"), 'health' }

    -- Non-blocking start function
    if service.start == nil then
        log.error("Service start function is nil")
        return
    end
    service:start(child_ctx, bus_connection)
    bus_connection:publish(new_msg(
        health_topic,
        { name = child_ctx:value("service_name"), state = STATE.ACTIVE },
        { retained = true }
    ))

    -- Creates a shutdown fiber to handle any shutdown messages from the system service
    -- Tracks all long running fibers under the current service before reporting an end to the service
    fiber.spawn(function ()
        local system_events_sub = bus_connection:subscribe({ child_ctx:value("service_name"), 'control', 'shutdown' })
        local shutdown_event = system_events_sub:next_msg()
        system_events_sub:unsubscribe()

        -- let every fiber know to end
        cancel_fn(shutdown_event.payload.cause)
        local service_fibers_status_sub = bus_connection:subscribe(
            { child_ctx:value("service_name"), 'health', 'fibers', '+' }
        )
        local active_fibers = FiberRegister.new()

        -- collect what fibers are active or initialising
        local fiber_check_ctx = context.with_deadline(ctx, shutdown_event.payload.deadline)
        while true do
            local message, ctx_err = service_fibers_status_sub:next_msg_with_context_op(fiber_check_ctx):perform()
            if ctx_err then break end
            if message.payload.state == STATE.DISABLED then
                active_fibers:remove(message.payload.name)
            else
                active_fibers:add(message.payload.name, message.payload.state)
            end
        end

        -- if no active or initialising fibers, we can safely end the service
        if active_fibers:is_empty() then
            bus_connection:publish(new_msg(
                health_topic,
                { name = child_ctx:value("service_name"), state = STATE.DISABLED },
                { retained = true }
            ))
        end
    end)
end

local function spawn_fiber(name, bus_connection, ctx, fn)
    local child_ctx = context.with_cancel(ctx)
    child_ctx = context.with_value(child_ctx, "fiber_name", name)

    local fiber_topic = { child_ctx:value("service_name"), 'health', 'fibers', child_ctx:value("fiber_name") }

    bus_connection:publish(new_msg(
        fiber_topic,
        { name = child_ctx:value("fiber_name"), state = STATE.INITIALISING },
        { retained = true }
    ))

    fiber.spawn(function ()
        bus_connection:publish(new_msg(
            fiber_topic,
            { name = child_ctx:value("fiber_name"), state = STATE.ACTIVE },
            { retained = true }
        ))
        fn(child_ctx)
        bus_connection:publish(new_msg(
            fiber_topic,
            { name = child_ctx:value("fiber_name"), state = STATE.DISABLED },
            { retained = true }
        ))
    end)
end

return {
    spawn = spawn,
    spawn_fiber = spawn_fiber
}
