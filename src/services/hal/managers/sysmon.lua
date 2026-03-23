-- services/hal/managers/sysmon.lua
--
-- System Monitor HAL Manager.
-- Discovers thermal zones at startup via /sys/class/thermal/ and creates:
--   • one CpuDriver    → capability class 'cpu',     id '1'
--   • one MemoryDriver → capability class 'memory',  id '1'
--   • one ThermalDriver per thermal_zone* sysfs entry
--
-- All devices are emitted once as HAL DeviceEvents, then the manager
-- sleeps until its scope is cancelled.

local cpu_driver     = require "services.hal.drivers.cpu"
local memory_driver  = require "services.hal.drivers.memory"
local thermal_driver = require "services.hal.drivers.thermal"
local hal_types      = require "services.hal.types.core"

local fibers  = require "fibers"
local op      = require "fibers.op"
local sleep   = require "fibers.sleep"
local exec    = require "fibers.io.exec"

local log = require "services.log"

local STOP_TIMEOUT = 5.0

---@class SysmonManager
---@field scope Scope?
---@field started boolean
local SysmonManager = {
    started = false,
    scope   = nil,
}

---- helpers ----

--- List /sys/class/thermal/ and return table of {zone_id, sysfs_dir} entries.
---@return table zones  list of {zone_id: string, sysfs_dir: string}
local function discover_thermal_zones()
    local cmd = exec.command('ls', '/sys/class/thermal/')
    local out, status, code = fibers.perform(cmd:output_op())
    if status ~= 'exited' or code ~= 0 then
        log.warn("Sysmon Manager: failed to list /sys/class/thermal/:", tostring(code))
        return {}
    end

    local zones = {}
    for entry in (out or ''):gmatch('[^\n]+') do
        local n = entry:match('^thermal_zone(%d+)$')
        if n then
            zones[#zones + 1] = {
                zone_id   = 'zone' .. n,
                sysfs_dir = '/sys/class/thermal/thermal_zone' .. n,
            }
        end
    end
    return zones
end

--- Create, bind, start a driver and emit a HAL DeviceEvent.
---@param driver any
---@param class string
---@param id string
---@param meta table
---@param dev_ev_ch Channel
---@param cap_emit_ch Channel
---@return boolean ok
local function register_driver(driver, class, id, meta, dev_ev_ch, cap_emit_ch)
    local init_err = driver:init()
    if init_err ~= "" then
        log.error(("Sysmon Manager: failed to init driver %s/%s: %s"):format(
            class, id, init_err))
        return false
    end

    local capabilities, cap_err = driver:capabilities(cap_emit_ch)
    if cap_err ~= "" then
        log.error(("Sysmon Manager: failed to bind capabilities for %s/%s: %s"):format(
            class, id, cap_err))
        return false
    end

    local ok, start_err = driver:start()
    if not ok then
        log.error(("Sysmon Manager: failed to start driver %s/%s: %s"):format(
            class, id, start_err))
        return false
    end

    local device_event, ev_err = hal_types.new.DeviceEvent("added", class, id, meta, capabilities)
    if not device_event then
        log.error(("Sysmon Manager: failed to create DeviceEvent for %s/%s: %s"):format(
            class, id, ev_err))
        return false
    end
    dev_ev_ch:put(device_event)
    return true
end

---- manager fiber ----

---@param scope Scope
---@param dev_ev_ch Channel
---@param cap_emit_ch Channel
local function manager(scope, dev_ev_ch, cap_emit_ch)
    log.trace("Sysmon Manager: started")

    scope:finally(function()
        log.trace("Sysmon Manager: closed")
    end)

    -- ── CPU ──
    local cpu_drv, cpu_err = cpu_driver.new()
    if not cpu_drv then
        log.error("Sysmon Manager: failed to create CPU driver:", cpu_err)
    else
        register_driver(cpu_drv, 'cpu', '1', {}, dev_ev_ch, cap_emit_ch)
    end

    -- ── Memory ──
    local mem_drv, mem_err = memory_driver.new()
    if not mem_drv then
        log.error("Sysmon Manager: failed to create Memory driver:", mem_err)
    else
        register_driver(mem_drv, 'memory', '1', {}, dev_ev_ch, cap_emit_ch)
    end

    -- ── Thermal zones ──
    local zones = discover_thermal_zones()
    if #zones == 0 then
        log.info("Sysmon Manager: no thermal zones discovered")
    end
    for _, zone in ipairs(zones) do
        local therm_drv, therm_err = thermal_driver.new(zone.zone_id, zone.sysfs_dir)
        if not therm_drv then
            log.error(("Sysmon Manager: failed to create thermal driver for %s: %s"):format(
                zone.zone_id, therm_err))
        else
            register_driver(therm_drv, 'thermal', zone.zone_id,
                { zone = zone.zone_id, path = zone.sysfs_dir }, dev_ev_ch, cap_emit_ch)
        end
    end

    log.trace("Sysmon Manager: all devices registered")
end

---- public interface ----

---@param dev_ev_ch Channel
---@param cap_emit_ch Channel
---@return string error
function SysmonManager.start(dev_ev_ch, cap_emit_ch)
    if SysmonManager.started then
        return "Already started"
    end

    local scope, err = fibers.current_scope():child()
    if not scope then
        return "Failed to create child scope: " .. tostring(err)
    end
    SysmonManager.scope = scope

    scope:finally(function()
        local st, primary = scope:status()
        if st == 'failed' then
            log.error(("Sysmon Manager: error - %s"):format(tostring(primary)))
        end
        log.trace("Sysmon Manager: stopped")
    end)

    scope:spawn(manager, dev_ev_ch, cap_emit_ch)

    SysmonManager.started = true
    log.trace("Sysmon Manager: started")
    return ""
end

---@param timeout number?
---@return boolean ok
---@return string error
function SysmonManager.stop(timeout)
    if not SysmonManager.started then
        return false, "Not started"
    end
    timeout = timeout or STOP_TIMEOUT
    SysmonManager.scope:cancel('sysmon manager stopped')

    local source = fibers.perform(op.named_choice {
        join    = SysmonManager.scope:join_op(),
        timeout = sleep.sleep_op(timeout),
    })

    if source == 'timeout' then
        return false, "sysmon manager stop timeout"
    end
    SysmonManager.started = false
    return true, ""
end

---@param namespaces table
---@return boolean ok
---@return string error
function SysmonManager.apply_config(namespaces) -- luacheck: ignore
    return true, ""
end

return SysmonManager
