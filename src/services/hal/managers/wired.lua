-- services/hal/managers/wired.lua
-- Strict op-only HAL manager for semantic wired-provider capabilities.
--
-- Provider capabilities are derived from HAL configuration.  The manager
-- deliberately keeps wired-provider capabilities raw at the HAL boundary; the
-- Wired service combines them with Device assembly into public state/wired/... surfaces.

local fibers = require 'fibers'
local safe = require 'coxpcall'
local op = require 'fibers.op'
local channel = require 'fibers.channel'
local cond = require 'fibers.cond'

local strict = require 'services.hal.support.strict_manager'
local hal_types = require 'services.hal.types.core'
local cap_types = require 'services.hal.types.capabilities'
local backend_mod = require 'services.hal.drivers.wired'
local provider_runner = require 'services.hal.managers.wired.provider_runner'

local M = strict.api_table()

local state = {
	started = false,
	scope = nil,
	logger = nil,
	dev_ev_ch = nil,
	cap_emit_ch = nil,
	http_client_for = nil,
	runners = {},       -- provider_id -> provider runner handle
	controls = {},
	provider_ids = {},
	device_registered = false,
}

local function log(level, payload)
	if state.logger and type(state.logger[level]) == 'function' then state.logger[level](state.logger, payload) end
end

local function new_reply(ok, payload)
	return assert(hal_types.new.Reply(ok == true, payload))
end

local function reply(req, ok, payload)
	if not req or not req.reply_ch then return end
	fibers.perform(req.reply_ch:put_op(new_reply(ok, payload)))
end

local function sorted_keys(t)
	local keys = {}
	for k in pairs(t or {}) do keys[#keys + 1] = k end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	return keys
end

local function shallow_copy(t)
	local out = {}
	for k, v in pairs(t or {}) do out[k] = v end
	return out
end

local function list_signature(list)
	return table.concat(list or {}, '\0')
end

local function normalise_groups(groups, path)
	if type(groups) ~= 'table' then return nil, path .. '.groups must be a non-empty array' end
	local out = {}
	for i = 1, #groups do
		local group = groups[i]
		if type(group) ~= 'string' or group == '' then return nil, path .. '.groups[' .. tostring(i) .. '] must be a non-empty string' end
		out[#out + 1] = group
	end
	if #out == 0 then return nil, path .. '.groups must be a non-empty array' end
	return out, nil
end

local function provider_poll_plan(config)
	config = config or {}
	if config.poll_interval_s ~= nil then return nil, 'use poll, not poll_interval_s, for grouped wired polling' end
	if config.poll == nil then return nil, 'poll is required' end
	if type(config.poll) ~= 'table' then return nil, 'poll must be a table' end
	local out = {}
	for _, name in ipairs(sorted_keys(config.poll)) do
		local rec = config.poll[name]
		local path = 'poll.' .. tostring(name)
		if type(rec) ~= 'table' then return nil, path .. ' must be a table' end
		local interval_s = tonumber(rec.interval_s)
		if interval_s == nil or interval_s <= 0 then return nil, path .. '.interval_s must be a positive number' end
		local groups, gerr = normalise_groups(rec.groups, path)
		if not groups then return nil, gerr end
		out[#out + 1] = { name = tostring(name), interval_s = interval_s, groups = groups }
	end
	if #out == 0 then return nil, 'poll must contain at least one poll group' end
	return out, nil
end

local function emit_state(class, id, key, payload)
	local ev = assert(hal_types.new.Emit(class, id, 'state', key, payload))
	return state.cap_emit_ch:put_op(ev):wrap(function () return true, nil end)
end

local function emit_provider_state(provider_id, key, payload)
	local ok, err = fibers.perform(emit_state('wired-provider', provider_id, key, payload or {}))
	if ok == false or ok == nil then return nil, err end
	return true, nil
end

local function runner_result(provider_id, method, opts)
	local runner = state.runners[provider_id]
	if not runner then return { ok = false, err = 'wired provider not configured', code = 'not_configured' } end
	local opname = tostring(method) .. '_op'
	local fn = runner[opname]
	if type(fn) ~= 'function' then return { ok = false, err = 'wired runner missing ' .. opname } end
	local ok, runner_op = safe.pcall(function () return fn(runner, opts or {}) end)
	if not ok then return { ok = false, err = tostring(runner_op) } end
	if type(runner_op) ~= 'table' then return { ok = false, err = opname .. ' did not return an Op' } end
	local ok2, result = safe.pcall(function () return fibers.perform(runner_op) end)
	if not ok2 then return { ok = false, err = tostring(result) } end
	if type(result) == 'table' then return result end
	return { ok = result == true, result = result }
end

local function handle_request(provider_id, req)
	local verb = req and req.verb
	local opts = req and req.opts or {}
	local result
	if verb == 'snapshot' or verb == 'watch' or verb == 'apply_attachments' or verb == 'set_poe' or verb == 'bounce' then
		result = runner_result(provider_id, verb, opts)
	else
		result = { ok = false, err = 'unsupported wired-provider verb: ' .. tostring(verb) }
	end
	reply(req, result and result.ok == true, result)
end

local function control_loop(provider_id, ch)
	while true do
		local req = fibers.perform(ch:get_op())
		if req == nil then return end
		handle_request(provider_id, req)
	end
end

local function make_capability(provider_id)
	local ch = channel.new(16)
	state.controls[provider_id] = ch
	return assert(cap_types.new.WiredProviderCapability(provider_id, ch))
end

local function make_caps(provider_ids)
	local caps = {}
	for i = 1, #provider_ids do caps[#caps + 1] = make_capability(provider_ids[i]) end
	return caps
end

local function device_event_op(event_type, caps, ready_cond)
	local ev = assert(hal_types.new.DeviceEvent(event_type, 'wired', 'main', {
		source = 'host',
		source_id = 'wired',
		manager = 'wired',
	}, caps or {}, ready_cond))
	return state.dev_ev_ch:put_op(ev):wrap(function () return true, nil end)
end

local function close_control_channels()
	for _, ch in pairs(state.controls or {}) do if ch and type(ch.close) == 'function' then ch:close('reconfigured') end end
	state.controls = {}
end

local function stop_runners(reason)
	for _, runner in pairs(state.runners or {}) do
		if runner and type(runner.terminate) == 'function' then runner:terminate(reason or 'reconfigured') end
	end
	state.runners = {}
end

local function spawn_control_loops(provider_ids)
	for i = 1, #provider_ids do
		local id = provider_ids[i]
		state.scope:spawn(function () control_loop(id, state.controls[id]) end)
	end
end

local function normalise_provider_ids(config)
	config = config or {}
	local providers = config.providers
	if type(providers) ~= 'table' then return nil, 'wired providers must be declared in providers map' end
	local ids = {}
	local keys = sorted_keys(providers)
	for i = 1, #keys do
		local key = tostring(keys[i])
		local rec = providers[key]
		if key == '' then return nil, 'wired provider id must be a non-empty map key' end
		if type(rec) ~= 'table' then return nil, ('wired provider %s must be a table'):format(key) end
		if rec.id ~= nil then return nil, ('wired provider %s must use the map key as its id'):format(key) end
		ids[#ids + 1] = key
	end
	return ids, nil
end

local function configured_provider(config, provider_id)
	config = config or {}
	local providers = config.providers
	if type(providers) ~= 'table' then return nil end
	local rec = providers[provider_id]
	if type(rec) ~= 'table' then return nil end
	return shallow_copy(rec)
end

local function reconcile_device_caps(provider_ids, ready_cond)
	local new_sig = list_signature(provider_ids)
	local old_sig = list_signature(state.provider_ids)
	if new_sig == old_sig then return true, nil, ready_cond, true end

	if state.device_registered then
		local ok, err = fibers.perform(device_event_op('removed', {}))
		if ok == false or ok == nil then return nil, err or 'wired device remove event failed' end
		state.device_registered = false
	end

	close_control_channels()
	state.provider_ids = {}

	if #provider_ids == 0 then return true, nil, ready_cond, true end

	local caps = make_caps(provider_ids)
	spawn_control_loops(provider_ids)
	local ok, err = fibers.perform(device_event_op('added', caps, ready_cond))
	if ok == false or ok == nil then
		close_control_channels()
		return nil, err or 'wired device add event failed'
	end

	state.provider_ids = provider_ids
	state.device_registered = true
	return true, nil, ready_cond, false
end

function M.start_op(logger, dev_ev_ch, cap_emit_ch, opts)
	return op.guard(function ()
		if state.started then return op.always(true, nil) end
		local parent = fibers.current_scope()
		local child, cerr = parent:child()
		if not child then return op.always(false, cerr or 'wired manager scope create failed') end

		state.scope = child
		state.logger = logger
		state.dev_ev_ch = dev_ev_ch
		state.cap_emit_ch = cap_emit_ch
		state.http_client_for = opts and opts.http_client_for or nil
		state.controls = {}
		state.runners = {}
		state.provider_ids = {}
		state.device_registered = false

		child:finally(function (_, status, primary) M.terminate(primary or status or 'wired manager closed') end)
		state.started = true
		log('info', { what = 'wired_manager_started' })
		return op.always(true, nil)
	end)
end

local function terminate_prepared(prepared, reason)
	for _, rec in pairs(prepared or {}) do
		local backend_handle = rec and rec.backend_handle
		if backend_handle and not rec.owned_by_runner and type(backend_handle.terminate) == 'function' then
			backend_handle:terminate(reason or 'discarded')
		end
	end
end

local function terminate_runners(runners, reason)
	for _, runner in pairs(runners or {}) do
		if runner and type(runner.terminate) == 'function' then runner:terminate(reason or 'discarded') end
	end
end

local function prepare_providers(config, provider_ids)
	local prepared = {}
	for i = 1, #provider_ids do
		local id = provider_ids[i]
		local pcfg = configured_provider(config or {}, id)
		if not pcfg then
			terminate_prepared(prepared, 'prepare failed')
			return nil, ('wired provider %s missing configuration'):format(id)
		end

		local driver_config = {}
		for k, v in pairs(pcfg) do driver_config[k] = v end
		local poll_plan, poll_err = provider_poll_plan(driver_config)
		if not poll_plan then
			terminate_prepared(prepared, 'prepare failed')
			return nil, ('wired provider %s poll config failed: %s'):format(id, tostring(poll_err))
		end
		driver_config.poll = nil

		local driver_opts = { logger = state.logger, cap_emit_ch = state.cap_emit_ch, provider_id = id }
		if driver_config.provider == 'rtl8380m_http' then driver_opts.http_client_for = state.http_client_for end
		local backend_handle, err = backend_mod.new(driver_config, driver_opts)
		if not backend_handle then
			terminate_prepared(prepared, 'prepare failed')
			return nil, ('wired provider %s create failed: %s'):format(id, tostring(err))
		end
		prepared[id] = { backend_handle = backend_handle, provider_name = backend_handle.provider_name, poll_plan = poll_plan }
	end
	return prepared, nil
end

function M.apply_config_op(config)
	return op.guard(function ()
		if not state.started then return op.always(false, 'wired manager not started') end
		return fibers.run_scope_op(function ()
			local provider_ids, perr = normalise_provider_ids(config or {})
			if not provider_ids then return false, perr end

			local prepared, prep_err = prepare_providers(config or {}, provider_ids)
			if not prepared then return false, prep_err end

			local caps_ready_cond = cond.new()
			local runners = {}
			for i = 1, #provider_ids do
				local id = provider_ids[i]
				local rec = prepared[id]
				local runner, rerr = provider_runner.new({
					provider_id = id,
					provider_name = rec.provider_name,
					backend = rec.backend_handle,
					poll_plan = rec.poll_plan,
					ready_cond = caps_ready_cond,
					parent_scope = state.scope,
					emit_state = emit_provider_state,
					log = log,
				})
				if not runner then
					terminate_runners(runners, 'runner create failed')
					terminate_prepared(prepared, 'runner create failed')
					return false, ('wired provider %s runner failed: %s'):format(id, tostring(rerr))
				end
				rec.owned_by_runner = true
				runners[id] = runner
			end

			for i = 1, #provider_ids do
				local id = provider_ids[i]
				local spawned, spawn_err = runners[id]:start()
				if spawned ~= true then
					terminate_runners(runners, 'runner spawn failed')
					terminate_prepared(prepared, 'runner spawn failed')
					return false, ('wired provider %s runner failed: %s'):format(id, tostring(spawn_err))
				end
			end

			stop_runners('reconfigured')
			local ok, cerr, _, ready_now = reconcile_device_caps(provider_ids, caps_ready_cond)
			if ok ~= true then
				terminate_runners(runners, 'capability reconcile failed')
				return false, cerr
			end

			state.runners = {}
			for i = 1, #provider_ids do
				local id = provider_ids[i]
				state.runners[id] = runners[id]
			end
			if ready_now and caps_ready_cond then caps_ready_cond:signal() end
			log('info', { what = 'wired_manager_configured', providers = provider_ids })
			return true, nil
		end):wrap(function (status, report, ok_or_primary, err)
			if status == 'ok' then
				if ok_or_primary == true then return true, nil end
				return false, err or ok_or_primary or 'wired manager configuration failed'
			end
			return false, ok_or_primary or (report and report.primary) or status or 'wired manager configuration failed'
		end)
	end)
end

function M.shutdown_op(_timeout_s)
	return op.guard(function () M.terminate('shutdown'); return op.always(true, nil) end)
end

function M.terminate(reason)
	stop_runners(reason or 'terminated')
	close_control_channels()
	state.provider_ids = {}
	state.device_registered = false
	if state.scope then local scope = state.scope; state.scope = nil; scope:cancel(reason or 'terminated') end
	state.started = false
	state.logger = nil
	state.dev_ev_ch = nil
	state.cap_emit_ch = nil
	state.http_client_for = nil
	return true, nil
end

function M.fault_op()
	return strict.fault_op_for_state(state)
end

M._test = {
	normalise_provider_ids = normalise_provider_ids,
	provider_poll_plan = provider_poll_plan,
	groups_for_plans = provider_runner._test.groups_for_plans,
}

return M
