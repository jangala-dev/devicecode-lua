-- services/hal/managers/network.lua
-- Strict op-only HAL manager for semantic network capabilities.

local fibers = require 'fibers'
local op = require 'fibers.op'
local channel = require 'fibers.channel'

local strict = require 'services.hal.support.strict_manager'
local hal_types = require 'services.hal.types.core'
local cap_types = require 'services.hal.types.capabilities'
local driver_mod = require 'services.hal.drivers.network'

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

local function new_reply(ok, payload)
	local reply = assert(hal_types.new.Reply(ok == true, payload))
	return reply
end

local function reply(req, ok, payload)
	if not req or not req.reply_ch then return end
	fibers.perform(req.reply_ch:put_op(new_reply(ok, payload)))
end

local function call_driver(method, req)
	if not state.driver then
		return { ok = false, err = 'network driver not configured' }
	end
	local opname = tostring(method) .. '_op'
	local fn = state.driver[opname]
	if type(fn) ~= 'function' then
		return { ok = false, err = 'network driver missing ' .. opname }
	end

	local ok, driver_op = pcall(function () return fn(state.driver, req and req.opts or {}) end)
	if not ok then
		return { ok = false, err = tostring(driver_op) }
	end
	if type(driver_op) ~= 'table' then
		return { ok = false, err = opname .. ' did not return an Op' }
	end

	local ok2, result = pcall(function () return fibers.perform(driver_op) end)
	if not ok2 then
		return { ok = false, err = tostring(result) }
	end
	if type(result) == 'table' then return result end
	return { ok = result == true, result = result }
end

local function handle_request(kind, req)
	local verb = req and req.verb
	local result

	if kind == 'config' then
		if verb == 'validate' or verb == 'plan' or verb == 'apply' then
			result = call_driver(verb, req)
		else
			result = { ok = false, err = 'unsupported network-config verb: ' .. tostring(verb) }
		end
	elseif kind == 'state' then
		if verb == 'snapshot' then
			result = call_driver('snapshot', req)
		elseif verb == 'watch' then
			result = call_driver('watch', req)
		else
			result = { ok = false, err = 'unsupported network-state verb: ' .. tostring(verb) }
		end
	elseif kind == 'diagnostics' then
		if verb == 'probe_link' then
			result = call_driver('probe_link', req)
		elseif verb == 'read_counters' then
			result = call_driver('read_counters', req)
		else
			result = { ok = false, err = 'unsupported network-diagnostics verb: ' .. tostring(verb) }
		end
	else
		result = { ok = false, err = 'invalid network capability kind' }
	end

	reply(req, result and result.ok == true, result)
end

local function control_loop(kind, ch)
	while true do
		local req = fibers.perform(ch:get_op())
		if req == nil then return end
		handle_request(kind, req)
	end
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
		local parent = fibers.current_scope()
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

		child:spawn(function () control_loop('config', state.controls.config) end)
		child:spawn(function () control_loop('state', state.controls.state) end)
		child:spawn(function () control_loop('diagnostics', state.controls.diagnostics) end)

		return emit_added(dev_ev_ch, caps):wrap(function (ok, err)
			if ok == false or ok == nil then
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
			logger = logger,
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
