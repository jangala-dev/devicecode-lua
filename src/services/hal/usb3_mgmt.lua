local pipe = require 'pipe'
local log = require 'log'

local tools = require 'jng_tools'

local fiber = require "fibers.fiber"
local exec = require "fibers.exec"

local M = {}

local usb_hub_address_prefix = "/sys/devices/platform/scb/fd500000.pcie/pci0000:00/0000:00:00.0/0000:01:00.0/usb"
local usb_hub_port_subpaths = {
    [1] = {
        [1] = "1-1/1-1.1",
        [2] = "1-1/1-1.2",
        [3] = "1-1/1-1.3",
        [4] = "1-1/1-1.4",
    },
    [2] = {
        [1] = "2-1",
        [2] = "2-2",
    }
}

function M.is_device_on_hub_port(hub, port)
    if not usb_hub_port_subpaths[hub] then
        return false, "invalid hub specified"
    elseif not usb_hub_port_subpaths[hub][port] then
        return false, "invalid port specified for hub"
    end

    local isdir, err = tools.isdir(usb_hub_address_prefix..hub.."/"..usb_hub_port_subpaths[hub][port])
    -- if the dir is not there this gets passed up as a 'no such...' error, but really this is expected, ignoring
    if err ~= nil and not string.match(err, "No such file or directory") then
        log.warn("DEFAULT_ERROR", "unexpected error checking for device on hub port: "..err)
    end
    return isdir ~= nil and isdir or false
end

-- (de)authorises new connections to a usb hub
function M.set_usb_hub_auth_default(enabled, hub)
    if type(enabled) ~= "boolean" then
        return "default authorization of USB hub must be set with a boolean value"
    end
    local writeint = enabled and 1 or 0
    local err = exec.command('echo', writeint, '>', usb_hub_address_prefix..hub..'/authorized_default'):run()
    if err ~= nil then return "setting default authorization of USB hub failed, code: "..err end

    return nil
end

function M.clear_usb_3_0_hub()
    local is_hub_used = false
    -- iterating over the usb 3.0 hub ports (this is hub usb2 on the rpi 4)
    for i = 1, #usb_hub_port_subpaths[2] do
        local is_port_used, err = M.is_device_on_hub_port(2, i)
        if err ~= nil then return false, "error checking current usb3.0 connections: "..err end
        is_hub_used = is_hub_used or is_port_used
        if is_port_used then
            err = M.set_usb_port_auth(false, 2, i)
            if err ~= nil then return true, "error clearing current usb3.0 connections: "..err end
        end
    end

    return is_hub_used, nil
end

function M.repopulate_usb_3_0_hub()
    local is_hub_used = false
    -- iterating over the usb 3.0 hub ports (this is hub usb2 on the rpi 4)
    for i = 1, #usb_hub_port_subpaths[2] do
        local is_port_used, err = M.is_device_on_hub_port(2, i)
        if err ~= nil then return false, "error checking current usb3.0 connections: "..err end
        is_hub_used = is_hub_used or is_port_used
        if is_port_used then
            err = M.set_usb_port_auth(true, 2, i)
            if err ~= nil then return true, "error adding usb3.0 connections: "..err end
        end
    end

    return is_hub_used, nil
end

-- (de)authorises a given port of a given usb hub 
function M.set_usb_port_auth(enabled, hub, port)
    if type(enabled) ~= "boolean" then
        return "authorization of USB hub port must be set with a boolean value"
    end
    local writeint = enabled and 1 or 0
    local err = exec.command('echo', writeint, '>', usb_hub_address_prefix..hub..'/'..usb_hub_port_subpaths[hub][port]..'/authorized'):run()
    if err ~= 0 then return "setting authorization of USB hub port failed, code: "..err end

    return nil
end

-- powers the usb hub up or down 
function M.set_usb_hub_power(enabled, hub)
    if type(enabled) ~= "boolean" then
        return "power of USB hub must be set with a boolean value"
    end
    local writeint = enabled and 1 or 0
    local err = exec.command("uhubctl", "-e", "-l", hub, "-a ", writeint):run()
    if err ~= 0 then return "setting power of USB hub port failed, code: "..err end

    return nil
end


-- checks the pi bootloader_version's timestamp which contains the vl805 usb controller firmware
function M.get_vl805_version_timestamp()
    local x, out, err  = pipe.pipe("", "vcgencmd", {"bootloader_version"})
    if x ~= 0 then log.error("DEFAULT_OUT_ERR", out, err); err = err or ""; return nil, out..err end
    local timestamp = string.match(out, "timestamp%s+(%d+)")
    if timestamp == nil then return nil, "timestamp not found in bootloader version info" end
    return tonumber(timestamp), nil
end

return M
