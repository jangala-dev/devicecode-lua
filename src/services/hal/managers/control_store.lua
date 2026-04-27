-- services/hal/managers/control_store.lua
--
-- HAL manager for control_store providers. Each provider is a normal
-- manager-owned driver that advertises one capability of the same class.

local driver_mod = require 'services.hal.drivers.control_store_provider'
local hal_types = require 'services.hal.types.core'

local fibers = require 'fibers'
local op = require 'fibers.op'
local sleep = require 'fibers.sleep'

local STOP_TIMEOUT = 5.0

local function dlog(logger, level, payload)
    if logger and logger[level] then logger[level](logger, payload) end
end

local Manager = {
    started = false,
    scope = nil,
    logger = nil,
    dev_ev_ch = nil,
    cap_emit_ch = nil,
    drivers = {},
}

local function child_logger(id)
    if Manager.logger and Manager.logger.child then
        return Manager.logger:child({ component = 'driver', driver = 'control_store', id = id })
    end
    return Manager.logger
end

local function normalise_config(cfg)
    cfg = cfg or {}
    if type(cfg) ~= 'table' then return nil, 'control_store config must be a table' end

    local specs = cfg.stores
    if specs == nil and cfg[1] == nil then
        specs = { { id = 'update' } }
    elseif specs == nil then
        specs = cfg
    end
    if type(specs) ~= 'table' then return nil, 'control_store.stores must be a table' end

    local out = {}
    for i = 1, #specs do
        local rec = specs[i]
        if type(rec) ~= 'table' then return nil, ('control_store.stores[%d] must be a table'):format(i) end
        local id = rec.id or rec.name or 'update'
        if type(id) ~= 'string' or id == '' then return nil, ('control_store.stores[%d].id must be a non-empty string'):format(i) end
        if out[id] ~= nil then return nil, 'duplicate control_store provider id: ' .. id end
        local opts = {}
        for k, v in pairs(rec) do if k ~= 'id' and k ~= 'name' then opts[k] = v end end
        out[id] = { id = id, opts = opts }
    end
    return out, ''
end

local function register_driver(id, opts)
    if Manager.drivers[id] then return true, '' end

    local driver, err = driver_mod.new(id, opts, child_logger(id))
    if not driver then return false, tostring(err) end

    local init_err = driver:init()
    if init_err ~= '' then return false, tostring(init_err) end

    local caps, cap_err = driver:capabilities(Manager.cap_emit_ch)
    if cap_err ~= '' then return false, tostring(cap_err) end

    local ok, start_err = driver:start()
    if not ok then return false, tostring(start_err) end

    local ev, ev_err = hal_types.new.DeviceEvent('added', 'control_store', id, { provider = 'hal.control_store' }, caps)
    if not ev then return false, tostring(ev_err) end
    Manager.dev_ev_ch:put(ev)

    Manager.drivers[id] = { driver = driver, opts = opts }
    dlog(Manager.logger, 'info', { what = 'device_registered', class = 'control_store', id = id })
    return true, ''
end

local function unregister_driver(id)
    local rec = Manager.drivers[id]
    if not rec then return end
    Manager.drivers[id] = nil

    local ev = hal_types.new.DeviceEvent('removed', 'control_store', id, { provider = 'hal.control_store' }, {})
    if ev then Manager.dev_ev_ch:put(ev) end

    fibers.current_scope():spawn(function() rec.driver:stop(STOP_TIMEOUT) end)
end

function Manager.start(logger, dev_ev_ch, cap_emit_ch)
    if Manager.started then return 'Already started' end

    local scope, err = fibers.current_scope():child()
    if not scope then return 'Failed to create child scope: ' .. tostring(err) end

    Manager.scope = scope
    Manager.logger = logger
    Manager.dev_ev_ch = dev_ev_ch
    Manager.cap_emit_ch = cap_emit_ch
    Manager.drivers = {}

    scope:finally(function()
        local st, primary = scope:status()
        if st == 'failed' then dlog(Manager.logger, 'error', { what = 'scope_failed', err = tostring(primary), status = st }) end
        dlog(Manager.logger, 'debug', { what = 'stopped' })
    end)

    Manager.started = true
    dlog(Manager.logger, 'debug', { what = 'start_called' })
    return ''
end

function Manager.stop(timeout)
    if not Manager.started then return false, 'Not started' end
    timeout = timeout or STOP_TIMEOUT
    Manager.scope:cancel('control_store manager stopped')
    local source = fibers.perform(op.named_choice { join = Manager.scope:join_op(), timeout = sleep.sleep_op(timeout) })
    if source == 'timeout' then return false, 'control_store manager stop timeout' end
    Manager.started = false
    return true, ''
end

function Manager.apply_config(cfg)
    local specs, err = normalise_config(cfg)
    if not specs then return false, err end

    for id, spec in pairs(specs) do
        local ok, reg_err = register_driver(id, spec.opts)
        if not ok then return false, reg_err end
    end

    for id in pairs(Manager.drivers) do
        if not specs[id] then unregister_driver(id) end
    end

    return true, ''
end

return Manager
