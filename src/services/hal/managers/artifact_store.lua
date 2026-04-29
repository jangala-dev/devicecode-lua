---@module 'services.hal.managers.artifact_store'

local fibers     = require 'fibers'
local op         = require 'fibers.op'
local sleep      = require 'fibers.sleep'
local channel    = require 'fibers.channel'

local hal_types  = require 'services.hal.types.core'
local driver_mod = require 'services.hal.drivers.artifact_store_provider'

local M = {
	__op_only = true,
}

local STOP_TIMEOUT = 5.0

---@class ArtifactStoreManagerState
---@field started boolean
---@field scope Scope|nil
---@field logger table|nil
---@field dev_ev_ch Channel|nil
---@field cap_emit_ch Channel|nil
---@field cfg_ch Channel
---@field drivers table<string, any>
local S = {
	started     = false,
	scope       = nil,
	logger      = nil,
	dev_ev_ch   = nil,
	cap_emit_ch = nil,
	cfg_ch      = channel.new(8),
	drivers     = {},
}

local function dlog(logger, level, payload)
	if logger and logger[level] then
		logger[level](logger, payload)
	end
end

local function child_logger(id)
	if S.logger and S.logger.child then
		return S.logger:child({
			component = 'driver',
			driver    = 'artifact_store',
			id        = id,
		})
	end
	return S.logger
end

local function validate_config(cfg)
	cfg = cfg or {}

	if type(cfg) ~= 'table' then
		return false, 'artifact_store config must be a table'
	end

	local specs = cfg.stores
	if specs == nil and cfg[1] == nil then
		specs = { { id = 'main' } }
	elseif specs == nil then
		specs = cfg
	end

	if type(specs) ~= 'table' then
		return false, 'artifact_store.stores must be a table'
	end

	local seen = {}
	for i, rec in ipairs(specs) do
		if type(rec) ~= 'table' then
			return false, ('artifact_store.stores[%d] must be a table'):format(i)
		end

		local id = rec.id or rec.name or 'main'
		if type(id) ~= 'string' or id == '' then
			return false, ('artifact_store.stores[%d].id must be a non-empty string'):format(i)
		end

		if seen[id] then
			return false, 'duplicate artifact_store provider id: ' .. id
		end
		seen[id] = true
	end

	return true, nil
end

local function normalise_config(cfg)
	local specs = cfg.stores
	if specs == nil and cfg[1] == nil then
		specs = { { id = 'main' } }
	elseif specs == nil then
		specs = cfg
	end

	local out = {}
	for i = 1, #specs do
		local rec = specs[i]
		local id = rec.id or rec.name or 'main'
		local opts = {}
		for k, v in pairs(rec) do
			if k ~= 'id' and k ~= 'name' then
				opts[k] = v
			end
		end
		out[id] = { id = id, opts = opts }
	end
	return out
end

local function deep_equal(a, b, seen)
	if a == b then
		return true
	end

	local ta, tb = type(a), type(b)
	if ta ~= tb then
		return false
	end

	if ta ~= 'table' then
		return false
	end

	seen = seen or {}
	if seen[a] and seen[a] == b then
		return true
	end
	seen[a] = b

	for k, va in pairs(a) do
		if not deep_equal(va, b[k], seen) then
			return false
		end
	end

	for k in pairs(b) do
		if a[k] == nil then
			return false
		end
	end

	return true
end

local function driver_matches_spec(driver, spec)
	if not driver or not spec then
		return false
	end

	return deep_equal(driver.opts or {}, spec.opts or {})
end

local function emit_device_added_op(driver, caps)
	return op.guard(function ()
		local ev, err = hal_types.new.DeviceEvent(
			'added',
			'artifact_store',
			driver.id,
			{ provider = 'hal.artifact_store' },
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
			'artifact_store',
			driver.id,
			{ provider = 'hal.artifact_store' },
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

local function start_driver_op(id, opts)
	return fibers.run_scope_op(function ()
		local driver = driver_mod.new(id, opts, child_logger(id))

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
			fibers.perform(driver:start_op(assert(S.scope, 'artifact_store manager scope missing')))
		if not ok_start then
			return false, tostring(start_err)
		end
		started = true

		local ok_emit, emit_err = fibers.perform(emit_device_added_op(driver, caps))
		if not ok_emit then
			return false, tostring(emit_err)
		end

		S.drivers[id] = driver
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

local function reconcile_op(cfg)
	return fibers.run_scope_op(function ()
		local desired = normalise_config(cfg)

		for id, driver in pairs(S.drivers) do
			local spec = desired[id]
			local should_remove =
				(spec == nil)
				or (not driver_matches_spec(driver, spec))

			if should_remove then
				local ok_stop, stop_err = fibers.perform(stop_driver_op(id, driver))
				if not ok_stop then
					return false, stop_err
				end
			end
		end

		for id, spec in pairs(desired) do
			if not S.drivers[id] then
				local ok_start, start_err = fibers.perform(start_driver_op(id, spec.opts))
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
	local scope = assert(S.scope, 'artifact_store shell without scope')

	while true do
		local which, a, b = fibers.perform(fibers.named_choice{
			cfg  = S.cfg_ch:get_op(),
			stop = scope:not_ok_op(),
		})

		if which == 'stop' then
			local status, reason_or_primary = a, b
			dlog(S.logger, 'debug', {
				what   = 'artifact_store_shell_stopping',
				status = tostring(status),
				reason = tostring(reason_or_primary),
			})
			return
		end

		local req = a
		if not req then
			return
		end

		local ok, err = fibers.perform(reconcile_op(req.config))
		fibers.perform(req.reply_ch:put_op({
			ok  = ok,
			err = err,
		}))
	end
end

function M.start_op(logger, dev_ev_ch, cap_emit_ch)
	local owner_scope = fibers.current_scope()
	assert(owner_scope ~= nil, 'artifact_store.start_op must be called from inside a fiber')

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

function M.apply_config_op(cfg)
	return fibers.run_scope_op(function ()
		local ok, err = validate_config(cfg)
		if not ok then
			return false, err
		end
		if not S.started then
			return false, 'artifact_store manager not started'
		end

		local reply_ch = channel.new(1)

		fibers.perform(S.cfg_ch:put_op({
			config   = cfg,
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
		scope:cancel('artifact_store manager stopped')

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
				return false, 'artifact_store manager stop timeout'
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
