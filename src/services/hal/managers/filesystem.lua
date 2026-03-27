-- HAL modules
local fs_driver = require "services.hal.drivers.filesystem"
local hal_types = require "services.hal.types.core"

-- Fibers modules
local fibers = require "fibers"
local op = require "fibers.op"
local sleep = require "fibers.sleep"

-- Constants

local STOP_TIMEOUT = 5.0 -- seconds

---@alias Namespace { name: string, root: string }


---@class FilesystemManager
---@field scope Scope
---@field started boolean
---@field drivers table<string, FSDriver>
---@field dev_ev_ch Channel?
---@field cap_emit_ch Channel?
---@field logger table?
---@field last_names string[]
local FilesystemManager = {
    started = false,
    drivers = {},
    dev_ev_ch = nil,
    cap_emit_ch = nil,
    logger = nil,
    last_names = {},
}

local function mlog(level, payload)
    local logger = FilesystemManager.logger
    if logger and logger[level] then
        logger[level](logger, payload)
    end
end

---@param namespaces string[]
local function emit_removed_device(namespaces)
    local removed_event, removed_err = hal_types.new.DeviceEvent(
        "removed",
        "fs",
        "main",
        { namespaces = namespaces }
    )
    if not removed_event then
        mlog('error', { what = 'removed_device_event_create_failed', err = tostring(removed_err) })
        return
    end
    FilesystemManager.dev_ev_ch:put(removed_event)
end

---@param driver FSDriver
local function stop_driver(driver)
    mlog('debug', { what = 'stopping_previous_driver' })
    local stop_ok, stop_err = driver:stop(STOP_TIMEOUT)
    if not stop_ok then
        mlog('warn', { what = 'stop_previous_driver_failed', err = tostring(stop_err) })
    end
end

local function stop_previous_driver_and_emit()
    local prev_driver = FilesystemManager.drivers["main"]
    if not prev_driver then
        return
    end

    stop_driver(prev_driver)

    emit_removed_device(FilesystemManager.last_names)
    FilesystemManager.drivers["main"] = nil
end

---@param namespaces Namespace[]
---@return table<string, string> roots
---@return string[] names
---@return string error
local function build_roots(namespaces)
    local roots = {}
    local names = {}
    for _, ns in ipairs(namespaces) do
        if type(ns.name) ~= 'string' or type(ns.root) ~= 'string' then
            return {}, {}, "invalid namespace config"
        end
        roots[ns.name] = ns.root
        names[#names + 1] = ns.name
    end
    return roots, names, ""
end

---@param roots table<string, string>
---@return FSDriver? driver
---@return string error
local function init_driver(roots)
    local driver_logger = nil
    if FilesystemManager.logger and FilesystemManager.logger.child then
        driver_logger = FilesystemManager.logger:child({ component = 'driver', driver = 'filesystem', id = 'main' })
    end

    ---@type any
    local fs_driver_any = fs_driver
    local driver, drv_err = fs_driver_any.new(roots, driver_logger)
    if not driver then
        return nil, "failed to create filesystem driver: " .. tostring(drv_err)
    end

    local init_err = driver:init()
    if init_err ~= "" then
        return nil, "failed to init filesystem driver: " .. tostring(init_err)
    end

    return driver, ""
end

---@param driver FSDriver
---@return Capability[]? capabilities
---@return string error
local function apply_driver_capabilities(driver)
    local capabilities, cap_err = driver:capabilities(FilesystemManager.cap_emit_ch)
    if cap_err ~= "" then
        return nil, "failed to apply capabilities: " .. tostring(cap_err)
    end

    return capabilities, ""
end

---@param driver FSDriver
---@return string error
local function start_driver(driver)
    local ok, start_err = driver:start()
    if not ok then
        return "failed to start driver: " .. tostring(start_err)
    end

    return ""
end

---@param namespaces string[]
---@param capabilities Capability[]
local function emit_added_device(namespaces, capabilities)
    local device_event, ev_err = hal_types.new.DeviceEvent(
        "added",
        "fs",
        "main",
        { namespaces = namespaces },
        capabilities
    )
    if not device_event then
        mlog('error', { what = 'added_device_event_create_failed', err = tostring(ev_err) })
        return
    end

    FilesystemManager.dev_ev_ch:put(device_event)
end


---Starts the Filesystem Manager.
---@param logger table?
---@param dev_ev_ch Channel
---@param cap_emit_ch Channel
---@return string error
function FilesystemManager.start(logger, dev_ev_ch, cap_emit_ch)
    if FilesystemManager.started then
        return "Already started"
    end

    local scope, err = fibers.current_scope():child()
    if not scope then
        return "Failed to create child scope: " .. tostring(err)
    end
    FilesystemManager.scope = scope
    FilesystemManager.dev_ev_ch = dev_ev_ch
    FilesystemManager.cap_emit_ch = cap_emit_ch
    FilesystemManager.logger = logger

    -- Print out manager stack trace if scope closes on a failure
    scope:finally(function()
        local st, primary = scope:status()
        if st == 'failed' then
            mlog('error', { what = 'scope_failed', err = tostring(primary), status = st })
        end
        mlog('debug', { what = 'stopped' })
    end)

    FilesystemManager.started = true
    mlog('debug', { what = 'started' })
    return ""
end

---Stops the Filesystem Manager.
---@param timeout number? Timeout in seconds
---@return boolean ok
---@return string error
function FilesystemManager.stop(timeout)
    if not FilesystemManager.started then
        return false, "Not started"
    end
    timeout = timeout or STOP_TIMEOUT
    FilesystemManager.scope:cancel()

    local source = fibers.perform(op.named_choice {
        join = FilesystemManager.scope:join_op(),
        timeout = sleep.sleep_op(timeout)
    })

    if source == "timeout" then
        return false, "filesystem manager stop timeout"
    end
    FilesystemManager.started = false
    return true, ""
end

--- Check that config is a set of name-root pairs and that paths are valid
---@param namespaces Namespace[]
local function validate_config(namespaces)
    if type(namespaces) ~= 'table' then
        return false, "config must be a table of namespaces"
    end
    for _, ns in ipairs(namespaces) do
        if type(ns.name) ~= 'string' or type(ns.root) ~= 'string' then
            return false, "each namespace must have a name and root string"
        end
    end
    return true, ""
end

---Apply filesystem configuration by creating a driver with the given namespaces.
---This function is non-blocking and spawns a fiber to initialize the driver.
---Stored channels from start() are used. Must be called after start().
---@param namespaces Namespace[] List of {name, root} namespace configs
---@return boolean ok
---@return string error
function FilesystemManager.apply_config(namespaces)
    local valid, validate_err = validate_config(namespaces)
    if not valid then
        return false, validate_err
    end

    if not FilesystemManager.started then
        return false, "filesystem manager not started"
    end

    if FilesystemManager.dev_ev_ch == nil or FilesystemManager.cap_emit_ch == nil then
        return false, "channels not initialized (start must be called first)"
    end

    -- Spawn non-blocking fiber to create and initialize driver
    local ok, spawn_err = FilesystemManager.scope:spawn(function()
        stop_previous_driver_and_emit()

        local roots, names, roots_err = build_roots(namespaces)
        if roots_err ~= "" then
            mlog('error', { what = 'build_roots_failed', err = tostring(roots_err) })
            return
        end

        local driver, init_err = init_driver(roots)
        if not driver then
            mlog('error', { what = 'driver_init_failed', err = tostring(init_err) })
            return
        end

        local capabilities, cap_err = apply_driver_capabilities(driver)
        if not capabilities then
            mlog('error', { what = 'apply_capabilities_failed', err = tostring(cap_err) })
            return
        end

        local start_err = start_driver(driver)
        if start_err ~= "" then
            mlog('error', { what = 'driver_start_failed', err = tostring(start_err) })
            return
        end

        FilesystemManager.drivers["main"] = driver
        FilesystemManager.last_names = names
        emit_added_device(names, capabilities)
        mlog('info', { what = 'applied_config_created_driver', namespaces = names })
    end)

    if not ok then
        return false, "failed to spawn driver initialization: " .. tostring(spawn_err)
    end

    return true, ""
end

return FilesystemManager
