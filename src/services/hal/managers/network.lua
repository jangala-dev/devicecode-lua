-- services/hal/managers/network.lua
-- Strict op-only HAL manager for semantic network capabilities.

local op = require 'fibers.op'
local channel = require 'fibers.channel'

local strict = require 'services.hal.support.strict_manager'
local hal_types = require 'services.hal.types.core'
local cap_types = require 'services.hal.types.capabilities'
local control_loop = require 'services.hal.support.control_loop'
local driver_mod = require 'services.hal.drivers.network'
local safe = require 'coxpcall'

local M = strict.api_table()

local state = {
	started = false,
	scope = nil,
	logger = nil,
	dev_ev_ch = nil,
	cap_emit_ch = nil,
	driver = nil,
	controls = {},
}

local function log(level, payload)
	if state.logger and type(state.logger[level]) == 'function' then
		state.logger[level](state.logger, payload)
	end
end

local function result_to_reply_tuple(result)
	if type(result) == 'table' then
		return result.ok == true, result
	end
	return result == true, result
end

local function driver_method_op(method, req)
	return op.guard(function ()
		if not state.driver then
			return op.always(false, { ok = false, err = 'network driver not configured' })
		end

		local opname = tostring(method) .. '_op'
		local fn = state.driver[opname]
		if type(fn) ~= 'function' then
			return op.always(false, { ok = false, err = 'network driver missing ' .. opname })
		end

		local ok, driver_op = safe.pcall(function () return fn(state.driver, req and req.opts or {}) end)
		if not ok then
			return op.always(false, { ok = false, err = tostring(driver_op) })
		end
		if type(driver_op) ~= 'table' then
			return op.always(false, { ok = false, err = opname .. ' did not return an Op' })
		end

		return driver_op:wrap(result_to_reply_tuple)
	end)
end

local CONFIG_METHODS = {
	validate = function (_opts, req) return driver_method_op('validate', req) end,
	plan = function (_opts, req) return driver_method_op('plan', req) end,
	apply = function (_opts, req) return driver_method_op('apply', req) end,
	apply_live_weights = function (_opts, req) return driver_method_op('apply_live_weights', req) end,
	apply_shaping = function (_opts, req) return driver_method_op('apply_shaping', req) end,
}

local STATE_METHODS = {
	snapshot = function (_opts, req) return driver_method_op('snapshot', req) end,
	watch = function (_opts, req) return driver_method_op('watch', req) end,
}

local DIAGNOSTICS_METHODS = {
	probe_link = function (_opts, req) return driver_method_op('probe_link', req) end,
	read_counters = function (_opts, req) return driver_method_op('read_counters', req) end,
	speedtest = function (_opts, req) return driver_method_op('speedtest', req) end,
}

local function control_loop_for(kind, ch, methods)
	if tostring(kind) == 'config' then
		log('warn', {
			what = 'network_config_control_instrumented_build',
			marker = 'owned_activation_runner_v1',
		})
	end
	control_loop.run_request_loop(ch, methods, state.logger, 'network_' .. tostring(kind))
end

local function make_capabilities()
	local cfg_ch = channel.new(16)
	local state_ch = channel.new(16)
	local diag_ch = channel.new(16)
	state.controls.config = cfg_ch
	state.controls.state = state_ch
	state.controls.diagnostics = diag_ch

	local cfg_cap = assert(cap_types.new.NetworkConfigCapability('main', cfg_ch))
	local state_cap = assert(cap_types.new.NetworkStateCapability('main', state_ch))
	local diag_cap = assert(cap_types.new.NetworkDiagnosticsCapability('main', diag_ch))

	return { cfg_cap, state_cap, diag_cap }
end

local function emit_added(dev_ev_ch, caps)
	local ev = assert(hal_types.new.DeviceEvent('added', 'network', 'main', {
		source = 'host',
		manager = 'network',
	}, caps))
	return dev_ev_ch:put_op(ev)
end

function M.start_op(logger, dev_ev_ch, cap_emit_ch)
	return op.guard(function ()
		if state.started then return op.always(true, nil) end
		local parent = require('fibers').current_scope()
		local child, cerr = parent:child()
		if not child then return op.always(false, cerr or 'network manager scope create failed') end

		state.scope = child
		state.logger = logger
		state.dev_ev_ch = dev_ev_ch
		state.cap_emit_ch = cap_emit_ch
		state.controls = {}
		local caps = make_capabilities()

		child:finally(function (_, status, primary)
			M.terminate(primary or status or 'network manager closed')
		end)

		child:spawn(function () control_loop_for('config', state.controls.config, CONFIG_METHODS) end)
		child:spawn(function () control_loop_for('state', state.controls.state, STATE_METHODS) end)
		child:spawn(function () control_loop_for('diagnostics', state.controls.diagnostics, DIAGNOSTICS_METHODS) end)

		return emit_added(dev_ev_ch, caps):wrap(function (ok, err)
			if ok == false then
				child:cancel('device_event_failed')
				return false, err or 'network device event failed'
			end
			state.started = true
			log('info', { what = 'network_manager_started' })
			return true, nil
		end)
	end)
end

function M.apply_config_op(config)
	return op.guard(function ()
		if not state.started then return op.always(false, 'network manager not started') end
		local driver, err = driver_mod.new(config or {}, {
			cap_emit_ch = state.cap_emit_ch,
			logger = state.logger,
			owner_scope = state.scope,
		})
		if not driver then return op.always(false, err or 'network driver create failed') end
		if state.driver and type(state.driver.terminate) == 'function' then
			state.driver:terminate('replaced')
		end
		state.driver = driver
		log('info', { what = 'network_driver_configured', provider = (config and (config.provider or config.backend)) or 'fake' })
		return op.always(true, nil)
	end)
end

function M.shutdown_op(_timeout_s)
	return op.guard(function ()
		M.terminate('shutdown')
		return op.always(true, nil)
	end)
end

function M.terminate(reason)
	if state.driver and type(state.driver.terminate) == 'function' then
		state.driver:terminate(reason or 'terminated')
	end
	state.driver = nil
	for _, ch in pairs(state.controls or {}) do
		if ch and type(ch.close) == 'function' then ch:close(reason or 'terminated') end
	end
	state.controls = {}
	if state.scope then
		local scope = state.scope
		state.scope = nil
		scope:cancel(reason or 'terminated')
	end
	state.started = false
	state.logger = nil
	state.dev_ev_ch = nil
	state.cap_emit_ch = nil
	return true, nil
end

function M.fault_op()
	return strict.fault_op_for_state(state)
end

return M
