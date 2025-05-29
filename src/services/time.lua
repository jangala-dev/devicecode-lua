-- Importing necessary modules
local fiber = require "fibers.fiber"
local op = require "fibers.op"
local exec = require 'fibers.exec'
local alarm = require 'fibers.alarm'
local cjson = require "cjson.safe"
local log = require 'services.log'
local new_msg = require('bus').new_msg

local time_service = {
    name = "time"
}
time_service.__index = time_service

local function ntpd_monitor(ctx)
    -- now we start a continuous loop to monitor for changes in interface state
    local cmd = exec.command("ubus", "listen", "hotplug.ntp")
    local stdout = cmd:stdout_pipe()
    if not stdout then
        log.error("TIME: could not create stdout pipe for ubus listen")
        return
    end

    local err = cmd:start()
    if err then
        log.error("TIME: ubus listen failed:", err)
        return
    end

    local err = exec.command("/etc/init.d/sysntpd", "restart"):run()
    if err then
        log.error("TIME: ubus listen failed:", err)
        return
    end

    local process_ended = false

    while not ctx:err() and not process_ended do
        op.choice(
            stdout:read_line_op():wrap(function(line)
                if not line then
                    log.error("TIME: ubus listen unexpectedly exited")
                    process_ended = true
                else
                    local event, err = cjson.decode(line)
                    if err then
                        log.error("TIME: ubus listen line decode failed:", err)
                        return
                    end
                    log.debug("TIME: ntpd hotplug event received!")
                    if event["hotplug.ntp"] and event["hotplug.ntp"].stratum then
                        if event["hotplug.ntp"].stratum ~= 16 then
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
                        log.warn("Received unknown")
                    end
                end
            end),
            ctx:done_op():wrap(function()
                cmd:kill()
            end)
        ):perform()
    end
    cmd:wait()
    stdout:close()
end

function time_service:start(root_ctx, bus_connection)
    alarm.install_alarm_handler()
    self.bus_connection = bus_connection
    fiber.spawn(function() ntpd_monitor(root_ctx) end)
end

return time_service
