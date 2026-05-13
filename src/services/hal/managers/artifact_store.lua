---@module 'services.hal.managers.artifact_store'

local fibers     = require 'fibers'
local op         = require 'fibers.op'
local sleep      = require 'fibers.sleep'
local channel    = require 'fibers.channel'

local device_events = require 'services.hal.support.device_events'
local driver_reconcile = require 'services.hal.support.driver_reconcile'
local strict_manager  = require 'services.hal.support.strict_manager'
local tablex          = require 'shared.table'
local resource   = require 'devicecode.support.resource'
local driver_mod = require 'services.hal.drivers.artifact_store_provider'

local M = {
	api_mode = 'op_only',
}


local STOP_TIMEOUT = 5.0

---@class ArtifactStoreManagerState
---@field started boolean
---@field scope Scope|nil
---@field logger table|nil
---@field dev_ev_ch Channel|nil
---@field cap_emit_ch Channel|nil
---@field cfg_ch Channel|nil
---@field generation integer
---@field drivers table<string, any>
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

local deep_equal = tablex.deep_equal

local function driver_matches_spec(driver, spec)
	if not driver or not spec then
		return false
	end

	return deep_equal(driver.opts or {}, spec.opts or {})
end

local function emit_device_added_op(driver, caps)
	return device_events.added_op(S.dev_ev_ch, 'artifact_store', driver.id, { provider = 'hal.artifact_store' }, caps)
end

local function emit_device_removed_op(driver)
	return device_events.removed_op(S.dev_ev_ch, 'artifact_store', driver.id, { provider = 'hal.artifact_store' })
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
				resource.terminate_checked(driver, 'manager cleanup', 'HAL manager driver rollback failed')
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

local function reconcile_op(cfg)
	local desired = normalise_config(cfg)
	return driver_reconcile.reconcile_op {
		current = S.drivers,
		desired = desired,
		same = driver_matches_spec,
		stop = stop_driver_op,
		start = function (id, spec) return start_driver_op(id, spec.opts) end,
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
	assert(S.scope, 'artifact_store shell without scope')

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

function M.apply_config_op(cfg)
	return fibers.run_scope_op(function ()
		local ok, err = validate_config(cfg)
		if not ok then
			return false, err
		end
		if not S.started then
			return false, 'artifact_store manager not started'
		end

		local cfg_ch = S.cfg_ch
		local generation = S.generation
		if not cfg_ch then
			return false, 'artifact_store manager not started'
		end

		local reply_ch = channel.new(1)
		local admitted, admit_err = fibers.perform(cfg_ch:put_op({
			generation = generation,
			config     = cfg,
			reply_ch   = reply_ch,
		}):wrap(function ()
			return true, nil
		end):or_else(function ()
			return false, 'artifact_store_manager_config_busy'
		end))

		if admitted ~= true then
			return false, tostring(admit_err or 'artifact_store_manager_config_busy')
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
		scope:cancel('artifact_store manager stopped')

		return fibers.boolean_choice(
			scope:join_op():wrap(function ()
				finalise_manager_scope(scope, generation)
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

function M.terminate(reason)
	reason = tostring(reason or 'artifact_store manager terminated')

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
