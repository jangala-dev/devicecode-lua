local log = require 'log'

local sc = require "fibers.utils.syscall"

local context = require 'fibers.context'
local exec = require "fibers.exec"

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

local function is_device_on_hub_port(hub, port)
    if not usb_hub_port_subpaths[hub] then
        return false, "invalid hub specified"
    elseif not usb_hub_port_subpaths[hub][port] then
        return false, "invalid port specified for hub"
    end

    -- check if the port is in use
    local isdir, err = sc.access(usb_hub_address_prefix..hub.."/"..usb_hub_port_subpaths[hub][port], "r")
    return isdir == 0
end

-- (de)authorises a given port of a given usb hub
local function set_usb_port_auth(ctx, enabled, hub, port)
    if type(enabled) ~= "boolean" then
        return "authorization of USB hub port must be set with a boolean value"
    end
    local writeint = enabled and 1 or 0
    local usb_addr = usb_hub_address_prefix..hub..'/'..usb_hub_port_subpaths[hub][port]..'/authorized'
    local cmd = exec.command_context(context.with_timeout(ctx, 1), 'echo', writeint, '>', usb_addr)
    local out, err = cmd:combined_output()
    if err then return string.format("setting authorization of USB hub port failed, code: %s", err) end

    return nil
end

-- (de)authorises new connections to a usb hub
local function set_usb_hub_auth_default(ctx, enabled, hub)
    if type(enabled) ~= "boolean" then
        return "default authorization of USB hub must be set with a boolean value"
    end
    local writeint = enabled and 1 or 0
    local hub_addr = usb_hub_address_prefix..hub..'/authorized_default'
    local cmd = exec.command_context(context.with_timeout(ctx, 1), 'echo', writeint, '>', hub_addr)
    local out, err = cmd:combined_output()
    if err then return string.format("setting default authorization of USB hub failed, code: %s", err) end

    return nil
end

local function clear_usb_3_0_hub(ctx)
    local is_hub_used = false
    -- iterating over the usb 3.0 hub ports (this is hub usb2 on the rpi 4)
    for i = 1, #usb_hub_port_subpaths[2] do
        local is_port_used, err = is_device_on_hub_port(2, i)
        if err ~= nil then return false, "error checking current usb3.0 connections: "..err end
        is_hub_used = is_hub_used or is_port_used
        if is_port_used then
            err = set_usb_port_auth(ctx, false, 2, i)
            if err ~= nil then return true, "error clearing current usb3.0 connections: "..err end
        end
    end

    return is_hub_used, nil
end

local function repopulate_usb_3_0_hub(ctx)
    local is_hub_used = false
    -- iterating over the usb 3.0 hub ports (this is hub usb2 on the rpi 4)
    for i = 1, #usb_hub_port_subpaths[2] do
        local is_port_used, err = is_device_on_hub_port(2, i)
        if err ~= nil then return false, "error checking current usb3.0 connections: "..err end
        is_hub_used = is_hub_used or is_port_used
        if is_port_used then
            err = set_usb_port_auth(ctx, true, 2, i)
            if err ~= nil then return true, "error adding usb3.0 connections: "..err end
        end
    end

    return is_hub_used, nil
end

-- powers the usb hub up or down
local function set_usb_hub_power(ctx, enabled, hub)
    if type(enabled) ~= "boolean" then
        return "power of USB hub must be set with a boolean value"
    end
    local writeint = enabled and 1 or 0
    local cmd = exec.command_context(context.with_timeout(ctx, 1), 'uhubctl', '-e', '-l', hub, '-a', writeint)
    local out, err = cmd:combined_output()
    if err then return string.format("setting power of USB hub failed, code: %s", err) end

    return nil
end

-- checks the pi bootloader_version's timestamp which contains the vl805 usb controller firmware
local function get_vl805_version_timestamp(ctx)
    local cmd = exec.command_context(context.with_timeout(ctx, 1), 'vcgencmd', 'bootloader_version')
    local out, err = cmd:combined_output()
    if err then log.error("USB3: %s %s", out, err); err = err or ""; return nil, out..err end
    local timestamp = string.match(out, "timestamp%s+(%d+)")
    if timestamp == nil then return nil, "timestamp not found in bootloader version info" end
    return tonumber(timestamp), nil
end

return {
    is_device_on_hub_port = is_device_on_hub_port,
    set_usb_hub_auth_default = set_usb_hub_auth_default,
    clear_usb_3_0_hub = clear_usb_3_0_hub,
    repopulate_usb_3_0_hub = repopulate_usb_3_0_hub,
    set_usb_port_auth = set_usb_port_auth,
    set_usb_hub_power = set_usb_hub_power,
    get_vl805_version_timestamp = get_vl805_version_timestamp
}
