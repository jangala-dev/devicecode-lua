local context = require "fibers.context"
local fiber = require 'fibers.fiber'
local sleep           = require 'fibers.sleep'
local log             = require 'log'

local STATE           = { INITIALISING = 1, ACTIVE = 2, DISABLED = 3 }
local STR_STATE       = { "INITIALISING", "ACTIVE", "DISABLED" }

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
    local bus_connection, conn_err = bus:connect()
    if conn_err then return conn_err end
    local child_ctx = context.with_cancel(ctx)
    if service.name == nil then return 'Service does not contain a name attribute' end
    child_ctx.values.service_name = service.name

    local health_topic = string.format("%s/health", child_ctx:value("service_name"))

    -- Non-blocking start function
    if (service.start == nil) then
        return string.format('%s: Service does not contain a start method', child_ctx:value('service_name'))
    end
    bus_connection:publish({
        topic = health_topic,
        payload = {
            name = child_ctx:value("service_name"),
            state = STATE.ACTIVE
        },
        retained = true
    })
    service:start(bus_connection, child_ctx)

    -- Creates a shutdown fiber to handle any shutdown messages from the system service
    -- Tracks all long running fibers under the current service before reporting an end to the service
    fiber.spawn(function ()
        local function send_disabled()
            bus_connection:publish({
                topic = health_topic,
                payload = {
                    name = child_ctx:value("service_name"),
                    state = STATE.DISABLED
                },
                retained = true
            })
        end

        local system_events_sub, sub_err = bus_connection:subscribe(string.format(
            "%s/control/shutdown",
            child_ctx:value('service_name')
        ))
        if sub_err then
            log.error(string.format(
                "%s: shutdown fiber failed to subscribe to shutdown topic (%s)",
                ctx:value("service_name"),
                sub_err
            ))
            send_disabled()
            return
        end
        local shutdown_event = system_events_sub:next_msg()
        system_events_sub:unsubscribe()

        local service_fibers_status_topic = string.format("%s/health/fibers/+", child_ctx:value('service_name'))
        local service_fibers_status_sub, status_sub_err = bus_connection:subscribe(service_fibers_status_topic)
        if status_sub_err then
            log.error(string.format(
                "%s : shutdown fiber failed to subscribe to fiber health topic (%s)",
                ctx:value('service_name'),
                status_sub_err
            ))
            send_disabled()
            return
        end
        local active_fibers = FiberRegister.new()

        local fibers_checked = false

        -- collect what fibers are active or initialising
        while true do
            local message = service_fibers_status_sub:next_msg_op():perform_alt(function () fibers_checked = true end)
            if fibers_checked then break end
            if message.payload ~= '' then
                if message.payload.state == STATE.DISABLED then
                    active_fibers:remove(message.payload.name)
                else
                    active_fibers:add(message.payload.name, message.payload.state)
                end
            end
        end

        -- let every fiber know to end
        child_ctx:cancel(shutdown_event.payload.cause)

        -- wait for fibers to close
        while not active_fibers:is_empty() do
            local message = service_fibers_status_sub:next_msg()
            if message.payload ~= '' then
                if message.payload.state == STATE.DISABLED then
                    active_fibers:remove(message.payload.name)
                else
                    active_fibers:add(message.payload.name, message.payload.state)
                end
            end
        end

        send_disabled()
    end)
end

local function spawn_fiber(name, bus_connection, ctx, fn)
    if ctx.cancel == nil then return "provided context does not have cancellation ability" end
    if ctx:value('service_name') == nil then
        return "provided context does not have a service name, please make this context is owned by a service"
    end
    local child_ctx = context.with_cancel(ctx)
    child_ctx.values.fiber_name = name

    local fiber_topic = string.format(
        "%s/health/fibers/%s",
        child_ctx:value('service_name'),
        child_ctx:value('fiber_name'))

    bus_connection:publish({
        topic = fiber_topic,
        payload = {
            name = child_ctx:value("fiber_name"),
            state = STATE.INITIALISING
        },
        retained = true
    })

    fiber.spawn(function ()
        bus_connection:publish({
            topic = fiber_topic,
            payload = {
                name = child_ctx:value("fiber_name"),
                state = STATE.ACTIVE
            },
            retained = true
        })
        fn(child_ctx)
        bus_connection:publish({
            topic = fiber_topic,
            payload = {
                name = child_ctx:value("fiber_name"),
                state = STATE.DISABLED
            },
            retained = true
        })
    end)
end

return {
    spawn = spawn,
    spawn_fiber = spawn_fiber,
    STATE = STATE,
    STR_STATE = STR_STATE
}
