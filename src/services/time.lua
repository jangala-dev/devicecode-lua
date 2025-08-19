-- Importing necessary modules
local fiber = require "fibers.fiber"
local op = require "fibers.op"
local exec = require 'fibers.exec'
local alarm = require 'fibers.alarm'
local cjson = require "cjson.safe"
local log = require 'services.log'
local context = require "fibers.context"
local new_msg = require('bus').new_msg

local time_service = {
    name = "time"
}
time_service.__index = time_service

-- Constants
local BUS_TIMEOUT = 5

local function ntpd_monitor(ctx)
    -- Wait for ubus capability to be active
    local ubus_active_sub = time_service.bus_connection:subscribe({'hal', 'capability', 'ubus', '1'})
    ubus_active_sub:next_msg() -- Block until ubus capability is active

    log.trace("TIME: NTP monitor starting")

    -- Restart sysntpd
    local err = exec.command("/etc/init.d/sysntpd", "restart"):run()
    if err then
        log.error("TIME: sysntpd restart failed:", err)
        return
    end

    -- Start listening for hotplug.ntp events via HAL
    local listen_sub = time_service.bus_connection:request(new_msg(
        { 'hal', 'capability', 'ubus', '1', 'control', 'listen' },
        { 'hotplug.ntp' }
    ))
    local listen_response, ctx_err = listen_sub:next_msg_with_context(context.with_timeout(ctx, BUS_TIMEOUT))
    if ctx_err or listen_response.payload.err then
        local err = ctx_err or listen_response.payload.err
        log.error("TIME: ubus listen failed:", err)
        return
    end

    local stream_id = listen_response.payload.result.stream_id
    local hotplug_sub = time_service.bus_connection:subscribe(
        { 'hal', 'capability', 'ubus', '1', 'info', 'stream', stream_id }
    )
    local stream_end_sub = time_service.bus_connection:subscribe(
        { 'hal', 'capability', 'ubus', '1', 'info', 'stream', stream_id, 'closed' }
    )

    local process_ended = false

    while not ctx:err() and not process_ended do
        op.choice(
            hotplug_sub:next_msg_op():wrap(function(msg)
                local event = msg.payload
                if not event then return end
                local data = event["hotplug.ntp"]
                if data and data.stratum then
                    log.debug("TIME: ntpd hotplug event received!")
                    if data.stratum ~= 16 then
                        log.debug("TIME: ntp time synced!")
                        time_service.bus_connection:publish(new_msg({ "time", "ntp_synced" }, true,
                            { retained = true }))
                        alarm.clock_synced()
                    else
                        log.debug("TIME: ntp time desynced")
                        time_service.bus_connection:publish(new_msg({ "time", "ntp_synced" }, false,
                            { retained = true }))
                        alarm.clock_desynced()
                    end
                else
                    log.warn("TIME: Received unknown hotplug.ntp event")
                end
            end),
            stream_end_sub:next_msg_op():wrap(function(stream_ended)
                if stream_ended.payload then
                    process_ended = true
                end
            end),
            ctx:done_op():wrap(function()
                time_service.bus_connection:publish(new_msg(
                    { 'hal', 'capability', 'ubus', '1', 'control', 'stop_stream' },
                    { stream_id }
                ))
            end)
        ):perform()
    end
end

function time_service:start(root_ctx, bus_connection)
    alarm.install_alarm_handler()
    self.bus_connection = bus_connection
    fiber.spawn(function() ntpd_monitor(root_ctx) end)
end

return time_service
