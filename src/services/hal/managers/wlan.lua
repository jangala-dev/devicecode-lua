local hal_types   = require "services.hal.types.core"
local radio_driver = require "services.hal.drivers.radio"
local band_driver  = require "services.hal.drivers.band"

local fibers  = require "fibers"
local op      = require "fibers.op"
local sleep   = require "fibers.sleep"
local channel = require "fibers.channel"

local STOP_TIMEOUT = 5.0

local log  -- set in start()

---@class WLANManager
---@field scope Scope?
---@field started boolean
---@field radios table<string, { driver: RadioDriver, path: string, type: string }>
---@field band BandDriver?
---@field config_ch Channel
local WLANManager = {
    started   = false,
    radios    = {},
    band      = nil,
    scope     = nil,
    config_ch = channel.new(4),
}

------------------------------------------------------------------------
-- Internal helpers
------------------------------------------------------------------------

---Start a single radio driver and emit device-added event.
---Must be called from within the manager scope's context.
---@param name string
---@param dev_ev_ch Channel
---@param cap_emit_ch Channel
local function start_radio(name, dev_ev_ch, cap_emit_ch)
    local driver, drv_err = radio_driver.new(name, log:child({ radio = name }))
    if not driver then
        log:error({ what = 'create_radio_driver_failed', name = name, err = drv_err })
        return
    end

    local init_err = driver:init()
    if init_err ~= '' then
        log:error({ what = 'init_radio_driver_failed', name = name, err = init_err })
        return
    end

    local capabilities, cap_err = driver:capabilities(cap_emit_ch)
    if not capabilities then
        log:error({ what = 'radio_capabilities_failed', name = name, err = cap_err })
        return
    end

    local ok, start_err = driver:start()
    if not ok then
        log:error({ what = 'start_radio_driver_failed', name = name, err = start_err })
        return
    end

    WLANManager.radios[name] = {
        driver = driver,
        path   = driver.staged.path,
        type   = driver.staged.type,
    }

    local device_event, ev_err = hal_types.new.DeviceEvent(
        'added',
        'radio',
        name,
        {
            provider = 'hal',
            version  = 1,
            name     = name,
            path     = driver.staged.path,
            type     = driver.staged.type,
        },
        capabilities
    )
    if not device_event then
        log:error({ what = 'create_radio_device_event_failed', name = name, err = ev_err })
        return
    end

    dev_ev_ch:put(device_event)
    log:info({ what = 'radio_driver_started', name = name })
end

---Stop a single radio driver and emit device-removed event.
---@param name string
---@param dev_ev_ch Channel
local function stop_radio(name, dev_ev_ch)
    local entry = WLANManager.radios[name]
    if not entry then
        log:warn({ what = 'stop_radio_not_found', name = name })
        return
    end

    -- Cancel the driver's scope (structured concurrency handles cleanup)
    entry.driver.scope:cancel('removed by manager')
    WLANManager.radios[name] = nil

    -- HAL unregisters by class+id, so an empty capabilities list is fine here
    local device_event, ev_err = hal_types.new.DeviceEvent(
        'removed',
        'radio',
        name,
        {},
        {}
    )
    if not device_event then
        log:error({ what = 'create_radio_remove_event_failed', name = name, err = ev_err })
        return
    end
    dev_ev_ch:put(device_event)
    log:info({ what = 'radio_driver_stopped', name = name })
end

---Start the band driver and emit device-added event.
---@param dev_ev_ch Channel
---@param cap_emit_ch Channel
local function start_band(dev_ev_ch, cap_emit_ch)
    local driver, drv_err = band_driver.new(log:child({ driver = 'band' }))
    if not driver then
        log:warn({ what = 'create_band_driver_failed', err = drv_err })
        return
    end

    local init_err = driver:init()
    if init_err ~= '' then
        log:warn({ what = 'init_band_driver_failed', err = init_err })
        return
    end

    local capabilities, cap_err = driver:capabilities(cap_emit_ch)
    if not capabilities then
        log:warn({ what = 'band_capabilities_failed', err = cap_err })
        return
    end

    local ok, start_err = driver:start()
    if not ok then
        log:warn({ what = 'start_band_driver_failed', err = start_err })
        return
    end

    WLANManager.band = driver

    local device_event, ev_err = hal_types.new.DeviceEvent(
        'added',
        'band',
        '1',
        { provider = 'hal', version = 1 },
        capabilities
    )
    if not device_event then
        log:warn({ what = 'create_band_device_event_failed', err = ev_err })
        return
    end

    dev_ev_ch:put(device_event)
    log:info({ what = 'band_driver_started' })
end

---Reconcile running radio drivers against a new config.
---@param config table
---@param dev_ev_ch Channel
---@param cap_emit_ch Channel
local function reconcile_radios(config, dev_ev_ch, cap_emit_ch)
    local new_radios = {}
    if type(config.radios) == 'table' then
        for _, r in ipairs(config.radios) do
            if type(r.name) == 'string' and r.name ~= '' then
                new_radios[r.name] = r
            end
        end
    end

    -- Stop drivers no longer in config or whose path/type changed
    local to_stop = {}
    for name, entry in pairs(WLANManager.radios) do
        local new_r = new_radios[name]
        if not new_r then
            table.insert(to_stop, { name = name, reason = 'removed' })
        elseif (new_r.path or '') ~= entry.path or (new_r.type or '') ~= entry.type then
            table.insert(to_stop, { name = name, reason = 'changed' })
        end
    end
    for _, s in ipairs(to_stop) do
        log:info({ what = 'stopping_radio', name = s.name, reason = s.reason })
        stop_radio(s.name, dev_ev_ch)
    end

    -- Start new or replacement radios
    for name in pairs(new_radios) do
        if not WLANManager.radios[name] then
            start_radio(name, dev_ev_ch, cap_emit_ch)
        end
    end
end

------------------------------------------------------------------------
-- Manager fiber
------------------------------------------------------------------------

local function manager_fiber(dev_ev_ch, cap_emit_ch)
    local scope = fibers.current_scope()

    scope:finally(function()
        local st, primary = scope:status()
        if st == 'failed' then
            log:error({ what = 'wlan_manager_scope_error', err = tostring(primary) })
        end
        log:debug({ what = 'wlan_manager_stopped' })
    end)

    -- Start the band driver immediately (always, regardless of radio count).
    -- The band driver is persistent; it is not restarted on config updates.
    start_band(dev_ev_ch, cap_emit_ch)

    -- Watch for config updates and driver faults
    while true do
        -- Build fault ops for each running radio driver
        local fault_ops = {}
        for name, entry in pairs(WLANManager.radios) do
            table.insert(fault_ops, entry.driver.scope:fault_op():wrap(function() return name end))
        end

        local fault_op = op.never()
        if #fault_ops > 0 then
            fault_op = op.choice(unpack(fault_ops))
        end

        local source, val = fibers.perform(fibers.named_choice({
            config       = WLANManager.config_ch:get_op(),
            driver_fault = fault_op,
            cancel       = scope:cancel_op(),
        }))

        if source == 'cancel' then
            break
        elseif source == 'config' then
            log:info({ what = 'apply_config_received' })
            -- reconcile_radios handles both initial setup and subsequent updates
            reconcile_radios(val, dev_ev_ch, cap_emit_ch)
        elseif source == 'driver_fault' then
            local name = val
            log:error({ what = 'radio_driver_fault', name = tostring(name) })
            -- Remove from registry (scope already failed); emit device-removed
            if WLANManager.radios[name] then
                WLANManager.radios[name] = nil
                local device_event = hal_types.new.DeviceEvent('removed', 'radio', name, {}, {})
                if device_event then dev_ev_ch:put(device_event) end
            end
        end
    end
end

------------------------------------------------------------------------
-- Public manager interface
------------------------------------------------------------------------

---Start the WLAN Manager.
---Creates a child scope and launches the manager and driver fibers.
---@param logger table
---@param dev_ev_ch Channel
---@param cap_emit_ch Channel
---@return string err  "" on success
function WLANManager.start(logger, dev_ev_ch, cap_emit_ch)
    log = logger

    if WLANManager.started then
        return "already started"
    end

    local scope, scope_err = fibers.current_scope():child()
    if not scope then
        return "failed to create child scope: " .. tostring(scope_err)
    end
    WLANManager.scope = scope

    scope:spawn(manager_fiber, dev_ev_ch, cap_emit_ch)

    WLANManager.started = true
    log:debug({ what = 'wlan_manager_started' })
    return ""
end

---Apply a new device config to the WLAN Manager.
---The manager reconciles radio drivers against the new config.
---@param config table
---@return boolean ok
---@return string  err
function WLANManager.apply_config(config)
    if not WLANManager.started then
        return false, "not started"
    end
    WLANManager.config_ch:put(config)
    return true, ""
end

---Stop the WLAN Manager and all its child drivers.
---@param timeout number?
---@return boolean ok
---@return string  err
function WLANManager.stop(timeout)
    if not WLANManager.started then
        return false, "not started"
    end
    timeout = timeout or STOP_TIMEOUT
    WLANManager.scope:cancel()

    local source = fibers.perform(op.named_choice({
        join    = WLANManager.scope:join_op(),
        timeout = sleep.sleep_op(timeout),
    }))

    if source == 'timeout' then
        return false, "wlan manager stop timeout"
    end
    WLANManager.started = false
    return true, ""
end

return WLANManager
