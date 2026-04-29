---@module 'services.hal.managers.uart'

local fibers     = require 'fibers'
local op         = require 'fibers.op'
local sleep      = require 'fibers.sleep'
local channel    = require 'fibers.channel'

local hal_types  = require 'services.hal.types.core'
local driver_mod = require 'services.hal.drivers.uart'

local M = {
    __op_only = true,
}

local STOP_TIMEOUT = 5.0

---@class UARTManagerState
---@field started boolean
---@field scope Scope|nil
---@field logger table|nil
---@field dev_ev_ch Channel|nil
---@field cap_emit_ch Channel|nil
---@field cfg_ch Channel
---@field drivers table<string, UARTDriver>
local S = {
    started     = false,
    scope       = nil,
    logger      = nil,
    dev_ev_ch   = nil,
    cap_emit_ch = nil,
    cfg_ch      = channel.new(8),
    drivers     = {},
}

local function valid_mode(mode)
    return mode == nil
        or mode == '8N1'
        or mode == '7E1'
        or mode == '8O1'
end

local function validate_config(entries)
    if type(entries) ~= 'table' then
        return false, 'config must be a list'
    end

    for _, entry in ipairs(entries) do
        if type(entry) ~= 'table' then
            return false, 'each uart entry must be a table'
        end
        if type(entry.id) ~= 'string' or entry.id == '' then
            return false, 'uart entry id must be a non-empty string'
        end
        if type(entry.path) ~= 'string' or entry.path == '' then
            return false, 'uart entry path must be a non-empty string'
        end
        if entry.baud ~= nil and (type(entry.baud) ~= 'number' or entry.baud <= 0 or entry.baud % 1 ~= 0) then
            return false, 'uart entry baud must be a positive integer'
        end
        if not valid_mode(entry.mode) then
            return false, 'uart entry mode is invalid'
        end
    end

    return true, nil
end

local function emit_device_added_op(driver, caps)
    return op.guard(function ()
        local ev, err = hal_types.new.DeviceEvent(
            'added',
            'uart',
            driver.id,
            {
                path   = driver.path,
                baud   = driver.default_baud,
                mode   = driver.default_mode,
                source = 'uart_manager',
            },
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
            'uart',
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

local function same_driver_config(driver, entry)
    return driver.path == entry.path
        and driver.default_baud == entry.baud
        and driver.default_mode == entry.mode
end

local function start_driver_op(entry)
    return fibers.run_scope_op(function ()
        local driver = driver_mod.new(
            entry.id,
            entry.path,
            entry.baud,
            entry.mode,
            S.logger
        )

        local ok_caps, caps_or_err = fibers.perform(driver:capabilities_op(S.cap_emit_ch))
        if not ok_caps then
            return false, tostring(caps_or_err)
        end
        local caps = caps_or_err

        local started = false
        local handed_off = false

        local function cleanup_started_driver()
            if started and not handed_off then
                op.perform_raw(driver:stop_op())
            end
        end

        fibers.current_scope():finally(function ()
            cleanup_started_driver()
        end)

        local ok_start, start_err =
            fibers.perform(driver:start_op(assert(S.scope, 'uart manager scope missing')))
        if not ok_start then
            return false, tostring(start_err)
        end
        started = true

        local ok_emit, emit_err = fibers.perform(emit_device_added_op(driver, caps))
        if not ok_emit then
            return false, tostring(emit_err)
        end

        S.drivers[entry.id] = driver
        handed_off = true
        return true, nil
    end):wrap(function (st, rep, ok, err)
        if st ~= 'ok' then
            return false, tostring(err or rep)
        end
        return ok, err
    end)
end

local function stop_driver_op(id, driver)
    return fibers.run_scope_op(function ()
        local ok_emit, emit_err = fibers.perform(emit_device_removed_op(driver))
        if not ok_emit then
            return false, tostring(emit_err)
        end

        local ok_stop, stop_err = fibers.perform(driver:stop_op())
        if not ok_stop then
            return false, tostring(stop_err)
        end

        S.drivers[id] = nil
        return true, nil
    end):wrap(function (st, rep, ok, err)
        if st ~= 'ok' then
            return false, tostring(err or rep)
        end
        return ok, err
    end)
end

local function reconcile_op(entries)
    return fibers.run_scope_op(function ()
        local desired = {}
        for _, entry in ipairs(entries) do
            desired[entry.id] = entry
        end

        for id, driver in pairs(S.drivers) do
            local want = desired[id]
            if want == nil or not same_driver_config(driver, want) then
                local ok_stop, stop_err = fibers.perform(stop_driver_op(id, driver))
                if not ok_stop then
                    return false, stop_err
                end
            end
        end

        for id, entry in pairs(desired) do
            if not S.drivers[id] then
                local ok_start, start_err = fibers.perform(start_driver_op(entry))
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
    local scope = assert(S.scope, 'uart shell without scope')

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
        local _ = fibers.perform(req.reply_ch:put_op({ ok = ok, err = err }))
        _ = _
    end
end

function M.start_op(logger, dev_ev_ch, cap_emit_ch)
    local owner_scope = fibers.current_scope()
    assert(owner_scope ~= nil, 'uart.start_op must be called from inside a fiber')

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

function M.apply_config_op(entries)
    return fibers.run_scope_op(function ()
        local ok, err = validate_config(entries)
        if not ok then
            return false, err
        end
        if not S.started then
            return false, 'uart manager not started'
        end

        local reply_ch = channel.new(1)

        fibers.perform(S.cfg_ch:put_op({
            config   = entries,
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
                return false, 'uart manager stop timeout'
            end)
        ):wrap(function (completed, _a, b)
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
