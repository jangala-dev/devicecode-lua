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

---Turn off the USB3 hub and move peripherals to USB2
---@param ctx Context
---@param model string?
local function disable_usb3(ctx, model)
    if model ~= "bigbox-ss" then return end
    -- VL805 (usb hub controller) firmware needs to be past a certain version
    -- version was added 2019-09-10 so let's check our version is 2019-09-10 or later
    local vl805_supported_from = os.time({ year = 2019, month = 09, day = 10, hour = 0, min = 0, sec = 0 })
    local vl805_timestamp, err = get_vl805_version_timestamp(ctx)
    if err ~= nil or vl805_timestamp < vl805_supported_from then
        err = err or ""
        log.warn(string.format(
            "System: VL805 firmware version is %s, expected version >= %s %s",
            vl805_timestamp,
            vl805_supported_from,
            err
        ))
        return
    end
    -- deactivating any current usb 3.0 connections via deauthorisation
    local usb_3_0_used, err = clear_usb_3_0_hub(ctx)
    if err ~= nil then
        -- need to reauth devices just in case
        log.error(string.format("System: Error clearing usb 3.0 hub, attempting repopulation, %s", err))
        _, err = repopulate_usb_3_0_hub(ctx)
        if err ~= nil then
            log.error(string.format("System: Error reactivating usb 3.0 connections, %s", err))
        end
        err = set_usb_hub_auth_default(ctx, true, 2)
        if err ~= nil then
            log.error(string.format("System: Error default-reauthorising usb 3.0 connections, %s", err))
        end
        return
    elseif not usb_3_0_used then
        -- no need to make any changes
        log.info("System: NO_USB3")
        return
    end
    -- default deauthorising usb 3.0 hub, prevents future connections
    err = set_usb_hub_auth_default(ctx, false, 2)
    if err ~= nil then
        log.warn(string.format("System: Error default-deauthorising usb 3.0 connections, %s", err))
    end
    -- powering down usb 3.0 hub to initiate usb 2.0 connections
    err = set_usb_hub_power(ctx, false, 2)
    if err ~= nil then
        -- need to try power up the hub just in case, and reauth devices
        log.error(string.format("System: Error powering down usb 3.0 hub, attempting power up, %s", err))
        err = set_usb_hub_power(ctx, true, 2)
        if err ~= nil then
            log.error("System: Error powering up usb 3.0 hub, attempting repopulation, %s", err)
        end
        _, err = repopulate_usb_3_0_hub(ctx)
        if err ~= nil then
            log.error(string.format("System: Error reactivating usb 3.0 connections, %s", err))
        end
        err = set_usb_hub_auth_default(ctx, true, 2)
        if err ~= nil then log.warn(string.format("System: Error default-reauthorising usb 3.0 connections, %s", err)) end
        return
    end
    -- waiting to see any usb 3.0 devices detected on usb 2.0 before moving on
    local detection_retries = 10
    local awaiting_port_1, err = is_device_on_hub_port(2, 1)
    if err ~= nil then log.warn(string.format("System: Error detecting device on usb 3.0 hub port: %s ", err)) end
    local awaiting_port_2, err = is_device_on_hub_port(2, 2)
    if err ~= nil then log.warn(string.format("System: Error detecting device on usb 3.0 hub port: %s", err)) end
    for _ = 1, detection_retries do
        local port_1_ready = not (awaiting_port_1 and not is_device_on_hub_port(1, 1))
        local port_2_ready = not (awaiting_port_2 and not is_device_on_hub_port(1, 2))
        if port_1_ready and port_2_ready then return else sleep.sleep(1) end
    end
    log.warn(string.format("System: Deactivated usb 3.0 devices not detected on usb 2.0 hub ports, may be unstable"))
end
return {
    is_device_on_hub_port = is_device_on_hub_port,
    set_usb_hub_auth_default = set_usb_hub_auth_default,
    clear_usb_3_0_hub = clear_usb_3_0_hub,
    repopulate_usb_3_0_hub = repopulate_usb_3_0_hub,
    set_usb_port_auth = set_usb_port_auth,
    set_usb_hub_power = set_usb_hub_power,
    get_vl805_version_timestamp = get_vl805_version_timestamp,
    disable_usb3 = disable_usb3,
}
