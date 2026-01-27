local exec = require 'fibers.exec'
local sc = require 'fibers.utils.syscall'
local sleep = require 'fibers.sleep'
local log = require 'services.log'


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

    local isdir, err = sc.access(usb_hub_address_prefix .. hub .. "/" .. usb_hub_port_subpaths[hub][port], "rw")
    if err ~= nil and not string.match(err, "No such file or directory") then
        log.warn("DEFAULT_ERROR", "unexpected error checking for device on hub port: " .. err)
    end
    return isdir == 0
end

local function exec_write_to_file(path, value)
    local cmd = exec.command("/bin/sh", "-c", string.format("echo %d > %s", value, path))
    local _, err = cmd:combined_output()
    return err
end

local function set_usb_hub_auth_default(enabled, hub)
    if type(enabled) ~= "boolean" then
        return "default authorization of USB hub must be set with a boolean value"
    end
    local path = string.format("%s%s/authorized_default", usb_hub_address_prefix, hub)
    local err = exec_write_to_file(path, enabled and 1 or 0)
    if err then return "setting default authorization of USB hub failed: " .. err end
    return nil
end

local function set_usb_port_auth(enabled, hub, port)
    if type(enabled) ~= "boolean" then
        return "authorization of USB hub port must be set with a boolean value"
    end
    local path = string.format("%s%s/%s/authorized", usb_hub_address_prefix, hub, usb_hub_port_subpaths[hub][port])
    local err = exec_write_to_file(path, enabled and 1 or 0)
    if err then return "setting authorization of USB hub port failed: " .. err end
    return nil
end

local function clear_usb_3_0_hub()
    local is_hub_used = false
    for i = 1, #usb_hub_port_subpaths[2] do
        local is_port_used, err = is_device_on_hub_port(2, i)
        if err ~= nil then return false, "error checking current usb3.0 connections: " .. err end
        is_hub_used = is_hub_used or is_port_used
        if is_port_used then
            err = set_usb_port_auth(false, 2, i)
            if err ~= nil then return true, "error clearing current usb3.0 connections: " .. err end
        end
    end
    return is_hub_used, nil
end

local function repopulate_usb_3_0_hub()
    local is_hub_used = false
    for i = 1, #usb_hub_port_subpaths[2] do
        local is_port_used, err = is_device_on_hub_port(2, i)
        if err ~= nil then return false, "error checking current usb3.0 connections: " .. err end
        is_hub_used = is_hub_used or is_port_used
        if is_port_used then
            err = set_usb_port_auth(true, 2, i)
            if err ~= nil then return true, "error adding usb3.0 connections: " .. err end
        end
    end
    return is_hub_used, nil
end

local function set_usb_hub_power(enabled, hub)
    if type(enabled) ~= "boolean" then
        return "power of USB hub must be set with a boolean value"
    end
    local cmd = exec.command("uhubctl", "-e", "-l", tostring(hub), "-a", tostring(enabled and 1 or 0))
    local _, err = cmd:combined_output()
    if err then return "setting power of USB hub port failed: " .. err end
    return nil
end

local function get_vl805_version_timestamp()
    local cmd = exec.command("vcgencmd", "bootloader_version")
    local output, err = cmd:combined_output()
    if err then
        log.error("DEFAULT_OUT_ERR", output, err)
        err = err or ""
        return nil, output .. err
    end
    local timestamp = string.match(output, "timestamp%s+(%d+)")
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
    local vl805_timestamp, err = get_vl805_version_timestamp()
    if err ~= nil then
        log.warn("System: Could not verify VL805 firmware version, proceeding anyway")
    elseif vl805_timestamp < vl805_supported_from then
        log.warn(string.format(
            "System: VL805 firmware version is %s, expected version >= %s",
            vl805_timestamp,
            vl805_supported_from
        ))
        return
    end
    -- deactivating any current usb 3.0 connections via deauthorisation
    local usb_3_0_used, err = clear_usb_3_0_hub()
    if err ~= nil then
        -- need to reauth devices just in case
        log.error(string.format("System: Error clearing usb 3.0 hub, attempting repopulation, %s", err))
        _, err = repopulate_usb_3_0_hub()
        if err ~= nil then
            log.error(string.format("System: Error reactivating usb 3.0 connections, %s", err))
        end
        err = set_usb_hub_auth_default(true, 2)
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
    err = set_usb_hub_auth_default(false, 2)
    if err ~= nil then
        log.warn(string.format("System: Error default-deauthorising usb 3.0 connections, %s", err))
    end
    -- powering down usb 3.0 hub to initiate usb 2.0 connections
    err = set_usb_hub_power(false, 2)
    if err ~= nil then
        -- need to try power up the hub just in case, and reauth devices
        log.error(string.format("System: Error powering down usb 3.0 hub, attempting power up, %s", err))
        err = set_usb_hub_power(true, 2)
        if err ~= nil then
            log.error("System: Error powering up usb 3.0 hub, attempting repopulation, %s", err)
        end
        _, err = repopulate_usb_3_0_hub()
        if err ~= nil then
            log.error(string.format("System: Error reactivating usb 3.0 connections, %s", err))
        end
        err = set_usb_hub_auth_default(true, 2)
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
    disable_usb3 = disable_usb3
}
