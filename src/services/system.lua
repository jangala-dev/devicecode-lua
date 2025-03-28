local service = require "service"
local log = require "log"
local op = require "fibers.op"
local new_msg = require("bus").new_msg

local system_service = {
    name = 'system'
}
system_service.__index = system_service

-- Main system service loop
local function system_main(ctx, bus_conn)
    -- Subscribe to system-related topics
    local config_sub = bus_conn:subscribe({ 'config', 'system' })

    -- Get initial configuration
    local config, config_err = config_sub:next_msg_with_context_op(ctx):perform()
    if config_err then
        log.error(config_err)
        return
    end

    -- Publish device identity information
    local device_info = {
        id = ctx:value("device"),
        type = "device",
        -- Add more system information as needed
    }

    bus_conn:publish(new_msg(
        { 'system', 'device', 'identity' },
        device_info,
        { retained = true }
    ))

    -- Main event loop
    while not ctx:err() do
        op.choice(
            ctx:done_op(),
            config_sub:next_msg_op():wrap(function(config_msg)
                -- Handle system configuration updates
                log.info("System configuration updated")
                -- Process new config here
            end)
        ):perform()
    end
end

-- Start the system service
function system_service:start(ctx, bus_connection)
    log.trace("Starting System Service")
    service.spawn_fiber('System', bus_connection, ctx, function(fiber_ctx)
        system_main(fiber_ctx, bus_connection)
    end)
end

return system_service
