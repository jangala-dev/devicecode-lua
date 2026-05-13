---@module 'services.hal.managers.uart'

local fibers     = require 'fibers'
local op         = require 'fibers.op'
local sleep      = require 'fibers.sleep'
local channel    = require 'fibers.channel'

local device_events = require 'services.hal.support.device_events'
local driver_reconcile = require 'services.hal.support.driver_reconcile'
local strict_manager  = require 'services.hal.support.strict_manager'
local resource   = require 'devicecode.support.resource'
local driver_mod = require 'services.hal.drivers.uart'

local M = {
    api_mode = 'op_only',
}


local STOP_TIMEOUT = 5.0

---@class UARTManagerState
---@field started boolean
---@field scope Scope|nil
---@field logger table|nil
---@field dev_ev_ch Channel|nil
---@field cap_emit_ch Channel|nil
---@field cfg_ch Channel|nil
---@field generation integer
---@field drivers table<string, UARTDriver>
local S = {
    started     = false,
    scope       = nil,
    logger      = nil,
    dev_ev_ch   = nil,
    cap_emit_ch = nil,
    cfg_ch      = nil,
	generation  = 0,
    drivers     = {},
}

local function finalise_manager_scope(scope, generation)
	if S.scope ~= scope or S.generation ~= generation then
		return
	end

	for _, driver in pairs(S.drivers or {}) do
		resource.terminate_checked(driver, 'manager finalised', 'HAL manager driver cleanup failed')
	end

	S.started     = false
	S.scope       = nil
	S.logger      = nil
	S.dev_ev_ch   = nil
	S.cap_emit_ch = nil
	S.cfg_ch      = nil
	S.drivers     = {}
end

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
	return device_events.added_op(S.dev_ev_ch, 'uart', driver.id, {
		path   = driver.path,
		baud   = driver.default_baud,
		mode   = driver.default_mode,
		source = 'uart_manager',
	}, caps)
end

local function emit_device_removed_op(driver)
	return device_events.removed_op(S.dev_ev_ch, 'uart', driver.id, {})
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
                resource.terminate_checked(driver, 'manager cleanup', 'HAL manager driver rollback failed')
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

        local ok_stop, stop_err = fibers.perform(driver:shutdown_op())
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
	return driver_reconcile.reconcile_op {
		current = S.drivers,
		entries = entries,
		id_of = function (entry) return entry.id end,
		same = same_driver_config,
		stop = stop_driver_op,
		start = function (_, entry) return start_driver_op(entry) end,
	}
end

local function reply_config_op(req, reply)
	if type(req) ~= 'table'
		or type(req.reply_ch) ~= 'table'
		or type(req.reply_ch.put_op) ~= 'function'
	then
		return op.always(false, 'config reply channel missing')
	end

	return req.reply_ch:put_op(reply):wrap(function ()
		return true, nil
	end):or_else(function ()
		return false, 'reply_not_ready'
	end)
end

local function shell_loop(generation, cfg_ch)
	assert(S.scope, 'uart shell without scope')

	while true do
		local req = fibers.perform(cfg_ch:get_op())
		if not req then
			return
		end

		if req.generation ~= generation or S.generation ~= generation then
			fibers.perform(reply_config_op(req, {
				ok  = false,
				err = 'stale manager generation',
			}))
		else
			local ok_reconcile, reconcile_err = fibers.perform(reconcile_op(req.config))
			local replied, reply_err = fibers.perform(reply_config_op(req, {
				ok  = ok_reconcile,
				err = reconcile_err,
			}))

			if replied ~= true and S.logger and S.logger.warn then
				S.logger:warn({
					what = 'config_reply_failed',
					err  = tostring(reply_err),
				})
			end
		end
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

		S.cfg_ch      = channel.new(8)
		S.generation  = S.generation + 1
		local generation = S.generation
		local cfg_ch = S.cfg_ch

        local detach_finaliser = scope:finally(function ()
            finalise_manager_scope(scope, generation)
        end)

        local ok, serr = scope:spawn(function () shell_loop(generation, cfg_ch) end)
        if not ok then
            detach_finaliser()
            finalise_manager_scope(scope, generation)
            scope:cancel(tostring(serr or 'manager shell spawn failed'))
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

		local cfg_ch = S.cfg_ch
		local generation = S.generation
		if not cfg_ch then
			return false, 'uart manager not started'
		end

		local reply_ch = channel.new(1)
		local admitted, admit_err = fibers.perform(cfg_ch:put_op({
			generation = generation,
			config     = entries,
			reply_ch   = reply_ch,
		}):wrap(function ()
			return true, nil
		end):or_else(function ()
			return false, 'uart_manager_config_busy'
		end))

		if admitted ~= true then
			return false, tostring(admit_err or 'uart_manager_config_busy')
		end

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

function M.shutdown_op(timeout)
    timeout = timeout or STOP_TIMEOUT

    return op.guard(function ()
        if not S.started or not S.scope then
            return op.always(true, nil)
        end

        local scope = S.scope
		local generation = S.generation
        scope:cancel()

        return fibers.boolean_choice(
            scope:join_op():wrap(function ()
                finalise_manager_scope(scope, generation)
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

function M.terminate(reason)
	reason = tostring(reason or 'uart manager terminated')

	local scope = S.scope
	local generation = S.generation
	if scope then
		scope:cancel(reason)
	end

	finalise_manager_scope(scope, generation)
	return true, nil
end

function M.fault_op()
	return strict_manager.fault_op_for_state(S)
end

return M
