-- HAL modules
local time_driver = require "services.hal.drivers.time"
local hal_types = require "services.hal.types.core"

-- Fibers modules
local fibers = require "fibers"
local op = require "fibers.op"
local sleep = require "fibers.sleep"
local exec = require "fibers.io.exec"

-- Other modules
local log = require "services.log"

-- Constants

local STOP_TIMEOUT = 5.0 -- seconds
local HOTPLUG_DIR = "/etc/hotplug.d/ntp"
local HOTPLUG_SCRIPT_NAME = "ntp"

---@alias TimeDriverHandle table

---@class TimeManager
---@field scope Scope
---@field started boolean
---@field driver TimeDriverHandle?
---@field dev_ev_ch Channel?
---@field cap_emit_ch Channel?
local TimeManager = {
    started     = false,
    driver      = nil,
    dev_ev_ch   = nil,
    cap_emit_ch = nil,
}

---- Internal Utilities ----

---Emit a HAL device-added event for the time capability provider.
---@param driver TimeDriverHandle
---@param capabilities Capability[]
local function emit_device_added(driver, capabilities)
    local device_event, ev_err = hal_types.new.DeviceEvent(
        "added",
        "time",
        driver.id,
        { source = "ntp" },
        capabilities
    )
    if not device_event then
        log.error("Time Manager: failed to create device-added event:", ev_err)
        return
    end
    TimeManager.dev_ev_ch:put(device_event)
end

---Emit a HAL device-removed event for the time capability provider.
---@param driver TimeDriverHandle
local function emit_device_removed(driver)
    local device_event, ev_err = hal_types.new.DeviceEvent(
        "removed",
        "time",
        driver.id,
        {}
    )
    if not device_event then
        log.error("Time Manager: failed to create device-removed event:", ev_err)
        return
    end
    TimeManager.dev_ev_ch:put(device_event)
end

---Stop the currently running driver (if any) and notify HAL that the device was
---removed. Safe to call when no driver is running.
---@return nil
local function stop_existing_driver()
    local prev = TimeManager.driver
    if not prev then return end

    log.trace("Time Manager: stopping existing driver")
    local ok, stop_err = prev:stop(STOP_TIMEOUT)
    if not ok then
        log.warn("Time Manager: failed to stop previous driver:", stop_err)
    end

    emit_device_removed(prev)
    TimeManager.driver = nil
end

---Run a command and require a zero exit status.
---@param ... string argv
---@return boolean ok
---@return string? error
local function run_checked(...)
    local status, code, _, err = fibers.perform(exec.command(...):run_op())
    if status ~= 'exited' or code ~= 0 then
        return false, tostring(err or ("exit code " .. tostring(code)))
    end
    return true, nil
end

---Resolve the directory that contains this manager file.
---@return string dir
local function manager_dir()
    local source = debug.getinfo(1, 'S').source or ''
    source = source:gsub('^@', '')
    return source:match('^(.*)/[^/]+$') or '.'
end

---Install the NTP hotplug script into /etc/hotplug.d/ntp.
---@return boolean ok
---@return string? error
local function install_ntp_hotplug_script()
    local src = manager_dir() .. "/time/" .. HOTPLUG_SCRIPT_NAME
    local dst = HOTPLUG_DIR .. "/" .. HOTPLUG_SCRIPT_NAME

    local ok, err = run_checked("mkdir", "-p", HOTPLUG_DIR)
    if not ok then
        return false, "failed to create hotplug directory: " .. tostring(err)
    end

    ok, err = run_checked("cp", src, dst)
    if not ok then
        return false, "failed to copy hotplug script from " .. src .. ": " .. tostring(err)
    end

    ok, err = run_checked("chmod", "+x", dst)
    if not ok then
        return false, "failed to chmod hotplug script: " .. tostring(err)
    end

    return true, nil
end

---Initialise, apply capabilities, and start a new TimeDriver. Stops any previously
---running driver first. Called from within a manager-scope fiber so exec and channel
---operations are safe.
---@return nil
local function bring_up_driver()
    stop_existing_driver()

    local installed, install_err = install_ntp_hotplug_script()
    if not installed then
        log.error("Time Manager: failed to install NTP hotplug script:", install_err)
        return
    end

    local driver, new_err = time_driver.new()
    if not driver then
        log.error("Time Manager: failed to create driver:", new_err)
        return
    end

    local init_err = driver:init()
    if init_err ~= "" then
        log.error("Time Manager: failed to init driver:", init_err)
        return
    end

    local capabilities, cap_err = driver:capabilities(TimeManager.cap_emit_ch)
    if not capabilities then
        log.error("Time Manager: failed to apply capabilities:", cap_err)
        return
    end

    local ok, start_err = driver:start()
    if not ok then
        log.error("Time Manager: failed to start driver:", start_err)
        return
    end

    TimeManager.driver = driver
    emit_device_added(driver, capabilities)
    log.trace("Time Manager: driver started successfully, capability id =", driver.id)
end

---- Manager Lifecycle ----

---Start the Time Manager. Creates a child scope for managing the driver lifetime.
---@param dev_ev_ch Channel Device event channel (DeviceEvent messages to HAL)
---@param cap_emit_ch Channel Capability emit channel (Emit messages to HAL)
---@return string error Empty string on success.
function TimeManager.start(dev_ev_ch, cap_emit_ch)
    if TimeManager.started then
        return "already started"
    end

    local scope, sc_err = fibers.current_scope():child()
    if not scope then
        return "failed to create child scope: " .. tostring(sc_err)
    end

    TimeManager.scope = scope
    TimeManager.dev_ev_ch = dev_ev_ch
    TimeManager.cap_emit_ch = cap_emit_ch

    scope:finally(function()
        local st, primary = scope:status()
        if st == 'failed' then
            log.error(("Time Manager: error - %s"):format(tostring(primary)))
        end
        log.trace("Time Manager: stopped")
    end)

    TimeManager.started = true
    log.trace("Time Manager: started")
    return ""
end

---Stop the Time Manager and its driver. Cancels the manager scope which will
---propagate cancellation to any running driver scope.
---@param timeout number? Timeout in seconds. Defaults to 5.
---@return boolean ok
---@return string error
function TimeManager.stop(timeout)
    if not TimeManager.started then
        return false, "not started"
    end

    timeout = timeout or STOP_TIMEOUT
    TimeManager.scope:cancel()

    local source = fibers.perform(op.named_choice {
        join    = TimeManager.scope:join_op(),
        timeout = sleep.sleep_op(timeout),
    })

    if source == 'timeout' then
        return false, "time manager stop timeout"
    end

    TimeManager.started = false
    return true, ""
end

---Apply time manager configuration. Spawns a fiber to create and start the time
---driver. The time driver requires no user-supplied configuration (sysntpd path is
---fixed), so the config table is accepted for interface consistency but ignored.
---@param config table
---@return boolean ok
---@return string error
function TimeManager.apply_config(config) -- luacheck: ignore config
    if not TimeManager.started then
        return false, "time manager not started"
    end
    if TimeManager.dev_ev_ch == nil or TimeManager.cap_emit_ch == nil then
        return false, "channels not initialized (start must be called first)"
    end

    local ok, spawn_err = TimeManager.scope:spawn(function()
        bring_up_driver()
    end)
    if not ok then
        return false, "failed to spawn driver initialization: " .. tostring(spawn_err)
    end

    return true, ""
end

return TimeManager
