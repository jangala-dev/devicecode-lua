local context = require "fibers.context"
local fiber = require 'fibers.fiber'

local FiberRegister = {}
FiberRegister.__index = FiberRegister

function FiberRegister.new()
    return setmetatable({size = 0, fibers = {}}, FiberRegister)
end

function FiberRegister:push(name, status)
    if self.fibers[name] == nil then
        self.size = self.size + 1
    end
    self.fibers[name] = status
end

function FiberRegister:pop(name)
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
    local child_ctx = context.with_cancel(ctx)
    child_ctx.values.service_name = service.name

    local health_topic = child_ctx.values.service_name..'/health'

    -- Non-blocking start function
    service:start(bus_connection, child_ctx)
    bus_connection:publish({
        topic = health_topic,
        payload = {
            name = child_ctx.values.service_name,
            state = 'active'
        },
        retained = true
    })

    -- Creates a shutdown fiber to handle any shutdown messages from the system service
    -- Tracks all long running fibers under the current service before reporting an end to the service
    fiber.spawn(function ()
        local system_events_sub = bus_connection:subscribe(child_ctx.values.service_name..'/control/shutdown')
        local shutdown_event = system_events_sub:next_msg()
        system_events_sub:unsubscribe()

        local service_fibers_status_sub = bus_connection:subscribe(child_ctx.values.service_name..'/health/fibers/+')
        local active_fibers = FiberRegister.new()

        local fibers_checked = false

        -- is there a better way to do this? should be one loop or two for better readability?:
        -- 1. No fibers
        -- 2. All fibers already completed
        -- 3. Some fibers finished
        -- 4. All fibers finished
        -- 5. (opt) Could a fiber spin up during the shutdown and not be detected as ongoing?

        -- collect what fibers are active or initialising
        while true do
            local message = service_fibers_status_sub:next_msg_op():perform_alt(function () fibers_checked = true end)
            if fibers_checked then break end
            if message.payload ~= '' then
                if message.payload.state == 'disabled' then
                    active_fibers:pop(message.payload.name)
                else
                    active_fibers:push(message.payload.name, message.payload.state)
                end
            end
        end

        -- let every fiber know to end
        child_ctx:cancel(shutdown_event.payload.cause)

        -- wait for fibers to close
        while not active_fibers:is_empty() do
            local message = service_fibers_status_sub:next_msg()
            if message.payload ~= '' then
                if message.payload.state == 'disabled' then
                    active_fibers:pop(message.payload.name)
                else
                    active_fibers:push(message.payload.name, message.payload.state)
                end
            end
        end

        bus_connection:publish({
            topic = health_topic,
            payload = {
                name = child_ctx.values.service_name,
                state = 'disabled'
            },
            retained = true
        })
    end)
end

local function spawn_fiber(name, bus_connection, ctx, fn)
    local child_ctx = context.with_cancel(ctx)
    child_ctx.values.fiber_name = name

    local fiber_topic = child_ctx.values.service_name..'/health/fibers/'..child_ctx.values.fiber_name

    bus_connection:publish({
        topic = fiber_topic,
        payload = {
            name = child_ctx.values.fiber_name,
            state = 'initialising'
        },
        retained = true
    })

    fiber.spawn(function ()
        bus_connection:publish({
            topic = fiber_topic,
            payload = {
                name = child_ctx.values.fiber_name,
                state = 'active'
            },
            retained = true
        })
        fn(child_ctx)
        bus_connection:publish({
            topic = fiber_topic,
            payload = {
                name = child_ctx.values.fiber_name,
                state = 'disabled'
            },
            retained = true
        })
    end)
end

return {
    spawn = spawn,
    spawn_fiber = spawn_fiber
}