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

---@type any
local cpu_driver_any = cpu_driver
---@type any
local memory_driver_any = memory_driver
---@type any
local thermal_driver_any = thermal_driver

local fibers  = require "fibers"
local op      = require "fibers.op"
local sleep   = require "fibers.sleep"
local exec    = require "fibers.io.exec"

local STOP_TIMEOUT = 5.0

local function dlog(logger, level, payload)
    if logger and logger[level] then
        logger[level](logger, payload)
    end
end

---@class SysmonManager
---@field scope Scope?
---@field started boolean
---@field logger Logger?
local SysmonManager = {
    started = false,
    scope   = nil,
    logger  = nil,
}

---@param driver string
---@param id string
---@return Logger?
local function child_logger(driver, id)
    if SysmonManager.logger and SysmonManager.logger.child then
        return SysmonManager.logger:child({ component = 'driver', driver = driver, id = id })
    end
    return nil
end

---- helpers ----

--- List /sys/class/thermal/ and return table of {zone_id, sysfs_dir} entries.
---@return table zones  list of {zone_id: string, sysfs_dir: string}
local function discover_thermal_zones()
    local cmd = exec.command('ls', '/sys/class/thermal/')
    local out, status, code = fibers.perform(cmd:output_op())
    if status ~= 'exited' or code ~= 0 then
        dlog(SysmonManager.logger, 'warn', { what = 'thermal_discovery_failed', code = tostring(code) })
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
        dlog(SysmonManager.logger, 'error', { what = 'driver_init_failed', class = class, id = id, err = init_err })
        return false
    end

    local capabilities, cap_err = driver:capabilities(cap_emit_ch)
    if cap_err ~= "" then
        dlog(SysmonManager.logger, 'error', {
            what = 'bind_capabilities_failed', class = class, id = id, err = cap_err,
        })
        return false
    end

    local ok, start_err = driver:start()
    if not ok then
        dlog(SysmonManager.logger, 'error', { what = 'driver_start_failed', class = class, id = id, err = start_err })
        return false
    end

    local device_event, ev_err = hal_types.new.DeviceEvent("added", class, id, meta, capabilities)
    if not device_event then
        dlog(SysmonManager.logger, 'error', {
            what = 'device_event_create_failed', class = class, id = id, err = ev_err,
        })
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
    dlog(SysmonManager.logger, 'debug', { what = 'started' })

    scope:finally(function()
        dlog(SysmonManager.logger, 'debug', { what = 'closed' })
    end)

    -- ── CPU ──
    local cpu_drv, cpu_err = cpu_driver_any.new(child_logger('cpu', '1'))
    if not cpu_drv then
        dlog(SysmonManager.logger, 'error', {
            what = 'driver_create_failed', class = 'cpu', id = '1', err = cpu_err,
        })
    else
        register_driver(cpu_drv, 'cpu', '1', {}, dev_ev_ch, cap_emit_ch)
    end

    -- ── Memory ──
    local mem_drv, mem_err = memory_driver_any.new(child_logger('memory', '1'))
    if not mem_drv then
        dlog(SysmonManager.logger, 'error', {
            what = 'driver_create_failed', class = 'memory', id = '1', err = mem_err,
        })
    else
        register_driver(mem_drv, 'memory', '1', {}, dev_ev_ch, cap_emit_ch)
    end

    -- ── Thermal zones ──
    local zones = discover_thermal_zones()
    if #zones == 0 then
        dlog(SysmonManager.logger, 'info', { what = 'no_thermal_zones_discovered' })
    end
    for _, zone in ipairs(zones) do
        local therm_drv, therm_err = thermal_driver_any.new(
            zone.zone_id,
            zone.sysfs_dir,
            child_logger('thermal', zone.zone_id)
        )
        if not therm_drv then
            dlog(SysmonManager.logger, 'error', {
                what = 'driver_create_failed', class = 'thermal', id = zone.zone_id, err = therm_err,
            })
        else
            register_driver(therm_drv, 'thermal', zone.zone_id,
                { zone = zone.zone_id, path = zone.sysfs_dir }, dev_ev_ch, cap_emit_ch)
        end
    end

    dlog(SysmonManager.logger, 'info', { what = 'all_devices_registered' })
end

---- public interface ----

---@param logger Logger?
---@param dev_ev_ch Channel
---@param cap_emit_ch Channel
---@return string error
function SysmonManager.start(logger, dev_ev_ch, cap_emit_ch)
    if SysmonManager.started then
        return "Already started"
    end

    local scope, err = fibers.current_scope():child()
    if not scope then
        return "Failed to create child scope: " .. tostring(err)
    end
    SysmonManager.scope = scope
    SysmonManager.logger = logger

    scope:finally(function()
        local st, primary = scope:status()
        if st == 'failed' then
            dlog(SysmonManager.logger, 'error', { what = 'scope_failed', err = tostring(primary), status = st })
        end
        dlog(SysmonManager.logger, 'debug', { what = 'stopped' })
    end)

    scope:spawn(manager, dev_ev_ch, cap_emit_ch)

    SysmonManager.started = true
    dlog(SysmonManager.logger, 'debug', { what = 'start_called' })
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
