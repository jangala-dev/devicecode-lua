---@module 'services.hal.managers.control_store'

local fibers    = require 'fibers'
local op        = require 'fibers.op'
local sleep     = require 'fibers.sleep'
local channel   = require 'fibers.channel'

local hal_types  = require 'services.hal.types.core'
local driver_mod = require 'services.hal.drivers.control_store'

local M = {
    __op_only = true,
}

local STOP_TIMEOUT = 5.0

---@class ControlStoreManagerState
---@field started boolean
---@field scope Scope|nil
---@field logger table|nil
---@field dev_ev_ch Channel|nil
---@field cap_emit_ch Channel|nil
---@field cfg_ch Channel
---@field drivers table<string, ControlStoreDriver>
local S = {
    started     = false,
    scope       = nil,
    logger      = nil,
    dev_ev_ch   = nil,
    cap_emit_ch = nil,
    cfg_ch      = channel.new(8),
    drivers     = {},
}

local function validate_config(namespaces)
    if type(namespaces) ~= 'table' then
        return false, 'config must be a list'
    end
    for _, ns in ipairs(namespaces) do
        if type(ns) ~= 'table' then
            return false, 'each namespace must be a table'
        end
        if type(ns.name) ~= 'string' or ns.name == '' then
            return false, 'namespace.name must be a non-empty string'
        end
        if type(ns.root) ~= 'string' or ns.root == '' then
            return false, 'namespace.root must be a non-empty string'
        end
    end
    return true, nil
end

local function emit_device_added_op(driver, caps)
    return op.guard(function ()
        local ev, err = hal_types.new.DeviceEvent(
            'added',
            'control_store',
            driver.id,
            { root = driver.root, source = 'control_store_manager' },
            caps
        )
        if not ev then
            return op.always(false, tostring(err))
        end
        return S.dev_ev_ch:put_op(ev):wrap(function ()
            return true, nil
        end)
    end)
end

local function emit_device_removed_op(driver)
    return op.guard(function ()
        local ev, err = hal_types.new.DeviceEvent(
            'removed',
            'control_store',
            driver.id,
            {},
            {}
        )
        if not ev then
            return op.always(false, tostring(err))
        end
        return S.dev_ev_ch:put_op(ev):wrap(function ()
            return true, nil
        end)
    end)
end

local function start_driver_op(name, root)
    return fibers.run_scope_op(function ()
        local driver = driver_mod.new(name, root, S.logger)

        local ok_caps, caps_or_err = fibers.perform(driver:capabilities_op(S.cap_emit_ch))
        if not ok_caps then
        return false, tostring(caps_or_err)
        end
        local caps = caps_or_err

        local started = false
        local handed_off = false

        local function cleanup_started_driver()
        if started and not handed_off then
            -- Best-effort rollback; this resource belongs to this start attempt
            op.perform_raw(driver:stop_op())
        end
        end

        -- If anything below errors, rollback the started driver.
        fibers.current_scope():finally(function ()
        cleanup_started_driver()
        end)

        local ok_start, start_err =
        fibers.perform(driver:start_op(assert(S.scope, 'control_store manager scope missing')))
        if not ok_start then
        return false, tostring(start_err)
        end
        started = true

        local ok_emit, emit_err = fibers.perform(emit_device_added_op(driver, caps))
        if not ok_emit then
        return false, tostring(emit_err)
        end

        S.drivers[name] = driver
        handed_off = true
        return true, nil
    end):wrap(function (st, rep, ok, err)
        if st ~= 'ok' then
        return false, tostring(err or rep)
        end
        return ok, err
    end)
end

local function stop_driver_op(name, driver)
    return fibers.run_scope_op(function ()
        local ok_emit, emit_err = fibers.perform(emit_device_removed_op(driver))
        if not ok_emit then
            return false, tostring(emit_err)
        end

        local ok_stop, stop_err = fibers.perform(driver:stop_op())
        if not ok_stop then
            return false, tostring(stop_err)
        end

        S.drivers[name] = nil
        return true, nil
    end):wrap(function (st, rep, ok, err)
        if st ~= 'ok' then
            return false, tostring(err or rep)
        end
        return ok, err
    end)
end

local function reconcile_op(namespaces)
    return fibers.run_scope_op(function ()
        local desired = {}
        for _, ns in ipairs(namespaces) do
            desired[ns.name] = ns.root
        end

        for name, driver in pairs(S.drivers) do
            local want_root = desired[name]
            if want_root == nil or want_root ~= driver.root then
                local ok_stop, stop_err = fibers.perform(stop_driver_op(name, driver))
                if not ok_stop then
                    return false, stop_err
                end
            end
        end

        for name, root in pairs(desired) do
            if not S.drivers[name] then
                local ok_start, start_err = fibers.perform(start_driver_op(name, root))
                if not ok_start then
                    return false, start_err
                end
            end
        end

        return true, nil
    end):wrap(function (st, rep, ok, err)
        if st ~= 'ok' then
            return false, tostring(err or rep)
        end
        return ok, err
    end)
end

local function shell_loop()
    local scope = assert(S.scope, 'control_store shell without scope')

    while true do
        local which, a, b = fibers.perform(fibers.named_choice{
            cfg  = S.cfg_ch:get_op(),
            stop = scope:not_ok_op(),
        })

        if which == 'stop' then
            return
        end

        local req, recv_err = a, b
        if not req then
            return
        end

        local ok, err = fibers.perform(reconcile_op(req.config))
        fibers.perform(req.reply_ch:put_op({ ok = ok, err = err }))
    end
end

function M.start_op(logger, dev_ev_ch, cap_emit_ch)
    -- Capture the owning long-lived HAL scope now, not at perform time.
    -- This op may be passed around before being performed; the driver shell must
    -- still be parented to the manager/service scope that initiated startup.
    local owner_scope = fibers.current_scope()
    assert(owner_scope ~= nil, 'control_store.start_op must be called from inside a fiber')

    return op.guard(function ()
        if S.started then
            return op.always(false, 'already started')
        end

        local scope, err = owner_scope:child()
        if not scope then
            return op.always(false, tostring(err))
        end

        S.scope       = scope
        S.logger      = logger
        S.dev_ev_ch   = dev_ev_ch
        S.cap_emit_ch = cap_emit_ch

        local ok, serr = scope:spawn(shell_loop)
        if not ok then
            S.scope       = nil
            S.logger      = nil
            S.dev_ev_ch   = nil
            S.cap_emit_ch = nil
            return op.always(false, tostring(serr))
        end

        S.started = true
        return op.always(true, nil)
    end)
end

function M.apply_config_op(namespaces)
    return fibers.run_scope_op(function ()
        local ok, err = validate_config(namespaces)
        if not ok then
            return false, err
        end
        if not S.started then
            return false, 'control_store manager not started'
        end

        local reply_ch = channel.new(1)

        fibers.perform(S.cfg_ch:put_op({
            config   = namespaces,
            reply_ch = reply_ch,
        }))

        local reply, recv_err = fibers.perform(reply_ch:get_op())
        if not reply then
            return false, tostring(recv_err or 'config reply missing')
        end

        return reply.ok, reply.err
    end):wrap(function (st, rep, ok, err)
        if st ~= 'ok' then
            return false, tostring(err or rep)
        end
        return ok, err
    end)
end

function M.stop_op(timeout)
    timeout = timeout or STOP_TIMEOUT

    return op.guard(function ()
        if not S.started or not S.scope then
            return op.always(true, nil)
        end

        local scope = S.scope
        scope:cancel()

        return fibers.boolean_choice(
            scope:join_op():wrap(function ()
                S.started     = false
                S.scope       = nil
                S.logger      = nil
                S.dev_ev_ch   = nil
                S.cap_emit_ch = nil
                S.drivers     = {}
                return true, nil
            end),
            sleep.sleep_op(timeout):wrap(function ()
                return false, 'control_store manager stop timeout'
            end)
        ):wrap(function (completed, a, b)
            if completed then
                return true, nil
            end
            return false, b
        end)
    end)
end

function M.fault_op()
    if S.scope and S.started then
        return S.scope:fault_op()
    end
    return op.never()
end

return M
