-- HAL modules
local time_driver = require "services.hal.drivers.time"
local hal_types = require "services.hal.types.core"

-- Fibers modules
local fibers = require "fibers"
local op = require "fibers.op"
local sleep = require "fibers.sleep"
local exec = require "fibers.io.exec"

-- Other modules

-- Constants

local STOP_TIMEOUT = 5.0 -- seconds
local HOTPLUG_DIR = "/etc/hotplug.d/ntp"
local HOTPLUG_SCRIPT_NAME = "ntp"

---@alias TimeDriverHandle table

---@class TimeManager
---@field scope Scope
---@field logger Logger?
---@field started boolean
---@field driver TimeDriverHandle?
---@field dev_ev_ch Channel?
---@field cap_emit_ch Channel?
local TimeManager = {
    started     = false,
    driver      = nil,
    dev_ev_ch   = nil,
    cap_emit_ch = nil,
    logger      = nil,
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
        TimeManager.logger:error({ what = 'device_added_event_failed', err = tostring(ev_err) })
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
        TimeManager.logger:error({ what = 'device_removed_event_failed', err = tostring(ev_err) })
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

    TimeManager.logger:debug({ what = 'stopping_existing_driver' })
    local ok, stop_err = prev:stop(STOP_TIMEOUT)
    if not ok then
        TimeManager.logger:warn({ what = 'driver_stop_failed', err = tostring(stop_err) })
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
        TimeManager.logger:error({ what = 'hotplug_script_install_failed', err = tostring(install_err) })
        return
    end

    local driver, new_err = time_driver.new(TimeManager.logger:child({ component = 'driver' }))
    if not driver then
        TimeManager.logger:error({ what = 'driver_create_failed', err = tostring(new_err) })
        return
    end

    local init_err = driver:init()
    if init_err ~= "" then
        TimeManager.logger:error({ what = 'driver_init_failed', err = tostring(init_err) })
        return
    end

    local capabilities, cap_err = driver:capabilities(TimeManager.cap_emit_ch)
    if not capabilities then
        TimeManager.logger:error({ what = 'driver_capabilities_failed', err = tostring(cap_err) })
        return
    end

    local ok, start_err = driver:start()
    if not ok then
        TimeManager.logger:error({ what = 'driver_start_failed', err = tostring(start_err) })
        return
    end

    TimeManager.driver = driver
    emit_device_added(driver, capabilities)
    TimeManager.logger:debug({ what = 'driver_started', cap_id = tostring(driver.id) })
end

---- Manager Lifecycle ----

---Start the Time Manager. Creates a child scope for managing the driver lifetime.
---@param dev_ev_ch Channel Device event channel (DeviceEvent messages to HAL)
---@param cap_emit_ch Channel Capability emit channel (Emit messages to HAL)
---@return string error Empty string on success.
function TimeManager.start(logger, dev_ev_ch, cap_emit_ch)
    if TimeManager.started then
        return "already started"
    end

    local scope, sc_err = fibers.current_scope():child()
    if not scope then
        return "failed to create child scope: " .. tostring(sc_err)
    end

    TimeManager.scope = scope
    TimeManager.logger = logger
    TimeManager.dev_ev_ch = dev_ev_ch
    TimeManager.cap_emit_ch = cap_emit_ch

    scope:finally(function()
        local st, primary = scope:status()
        if st == 'failed' then
            logger:error({ what = 'scope_failed', err = tostring(primary), status = st })
        end
        logger:debug({ what = 'stopped' })
    end)

    TimeManager.started = true
    logger:debug({ what = 'started' })
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

    TimeManager.logger:debug({ what = 'config_received' })

    local ok, spawn_err = TimeManager.scope:spawn(function()
        bring_up_driver()
    end)
    if not ok then
        return false, "failed to spawn driver initialization: " .. tostring(spawn_err)
    end

    return true, ""
end

return TimeManager
