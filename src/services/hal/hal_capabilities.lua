local channel = require "fibers.channel"

local function do_command(driver_q, cmd)
    cmd.return_channel = channel.new()
    driver_q:put(cmd)
    return cmd.return_channel:get()
end

local ModemCapability = {}
ModemCapability.__index = ModemCapability

local function new_modem_capability(driver_q)
    return setmetatable({driver_q = driver_q}, ModemCapability)
end

function ModemCapability:enable()
    local cmd = {command = "enable"}
    return do_command(cmd, self.driver_q)
end

function ModemCapability:disable()
    local cmd = {command = "disable"}
    return do_command(cmd, self.driver_q)
end

function ModemCapability:restart()
    local cmd = {command = "restart"}
    return do_command(cmd, self.driver_q)
end

function ModemCapability:connect()
    local cmd = {command = "connect"}
    return do_command(cmd, self.driver_q)
end

function ModemCapability:disconnect()
    local cmd = {command = "disconnect"}
    return do_command(cmd, self.driver_q)
end

local GeoCapability = {}
GeoCapability.__index = GeoCapability

local function new_geo_capability(driver_q)
    return setmetatable({driver_q = driver_q}, GeoCapability)
end

local TimeCapability = {}
TimeCapability.__index = TimeCapability

local function new_time_capability(driver_q)
    return setmetatable({driver_q = driver_q}, GeoCapability)
end

return {
    new_modem_capability = new_modem_capability,
    new_geo_capability = new_geo_capability,
    new_time_capability = new_time_capability
}
