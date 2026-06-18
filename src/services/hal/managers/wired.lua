-- services/hal/managers/wired.lua
-- Strict op-only HAL manager for semantic wired-provider capabilities.
--
-- Provider capabilities are derived from HAL configuration.  The manager
-- deliberately keeps wired-provider capabilities raw at the HAL boundary; the
-- Wired service combines them with Device assembly into public state/wired/... surfaces.

local fibers = require 'fibers'
local op = require 'fibers.op'
local channel = require 'fibers.channel'
local cond = require 'fibers.cond'
local sleep = require 'fibers.sleep'
local runtime = require 'fibers.runtime'
local tablex = require 'shared.table'

local strict = require 'services.hal.support.strict_manager'
local hal_types = require 'services.hal.types.core'
local cap_types = require 'services.hal.types.capabilities'
local driver_mod = require 'services.hal.drivers.wired'

local M = strict.api_table()

local state = {
	started = false,
	scope = nil,
	logger = nil,
	dev_ev_ch = nil,
	cap_emit_ch = nil,
	http_client_for = nil,
	drivers = {},
	controls = {},
	provider_ids = {},
	pollers = {},
	observations = {},
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

local function copy(v) return tablex.deep_copy(v) end

local function merge_table(dst, src)
	dst = dst or {}
	if type(src) ~= 'table' then return dst end
	for k, v in pairs(src) do
		if v ~= nil then
			if type(v) == 'table' and type(dst[k]) == 'table' then
				merge_table(dst[k], v)
			else
				dst[k] = copy(v)
			end
		end
	end
	return dst
end

local function observation_cache(provider_id)
	state.observations = state.observations or {}
	local cache = state.observations[provider_id]
	if cache == nil then
		cache = {
			status = {},
			identity = {},
			runtime = {},
			power = {},
			surfaces = {},
			topology = {},
		}
		state.observations[provider_id] = cache
	end
	return cache
end

local function merge_observation(provider_id, snapshot)
	local cache = observation_cache(provider_id)
	snapshot = snapshot or {}
	if type(snapshot.status) == 'table' then merge_table(cache.status, snapshot.status) end
	for _, key in ipairs({ 'identity', 'runtime', 'power', 'topology' }) do
		if type(snapshot[key]) == 'table' then merge_table(cache[key], snapshot[key]) end
	end
	if type(snapshot.surfaces) == 'table' then
		for surface_id, surface in pairs(snapshot.surfaces) do
			local id = tostring(surface_id or '')
			if id ~= '' and type(surface) == 'table' then
				cache.surfaces[id] = merge_table(cache.surfaces[id] or {}, surface)
			end
		end
	end
	return cache
end

local function max(a, b) if a > b then return a end return b end

local function list_signature(list)
	return table.concat(list or {}, '\0')
end

local function emit_state(class, id, key, payload)
	local ev = assert(hal_types.new.Emit(class, id, 'state', key, payload))
	return state.cap_emit_ch:put_op(ev):wrap(function () return true, nil end)
end

local function emit_status_now(provider_id, status)
	local ok, err = fibers.perform(emit_state('wired-provider', provider_id, 'status', status or { state = 'available', available = true }))
	if ok == false or ok == nil then return nil, err end
	return true, nil
end

local function emit_snapshot_now(provider_id, snapshot)
	local ok, err = emit_status_now(provider_id, snapshot.status or { state = 'available', available = snapshot.ok == true })
	if ok ~= true then return nil, err end
	ok, err = fibers.perform(emit_state('wired-provider', provider_id, 'identity', snapshot.identity or {}))
	if ok == false or ok == nil then return nil, err end
	ok, err = fibers.perform(emit_state('wired-provider', provider_id, 'runtime', snapshot.runtime or {}))
	if ok == false or ok == nil then return nil, err end
	ok, err = fibers.perform(emit_state('wired-provider', provider_id, 'power', snapshot.power or {}))
	if ok == false or ok == nil then return nil, err end
	ok, err = fibers.perform(emit_state('wired-provider', provider_id, 'surfaces', { surfaces = snapshot.surfaces or {} }))
	if ok == false or ok == nil then return nil, err end
	ok, err = fibers.perform(emit_state('wired-provider', provider_id, 'topology', snapshot.topology or {}))
	if ok == false or ok == nil then return nil, err end
	return true, nil
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

local function perform_driver_method(driver, method, opts)
	local opname = tostring(method) .. '_op'
	local fn = driver and driver[opname]
	if type(fn) ~= 'function' then return { ok = false, err = 'wired driver missing ' .. opname } end
	local ok, driver_op = pcall(function () return fn(driver, opts or {}) end)
	if not ok then return { ok = false, err = tostring(driver_op) } end
	if type(driver_op) ~= 'table' then return { ok = false, err = opname .. ' did not return an Op' } end
	local ok2, result = pcall(function () return fibers.perform(driver_op) end)
	if not ok2 then return { ok = false, err = tostring(result) } end
	if type(result) == 'table' then return result end
	return { ok = result == true, result = result }
end

local function driver_result(provider_id, method, opts)
	local driver = state.drivers[provider_id]
	if not driver then return { ok = false, err = 'wired provider not configured', code = 'not_configured' } end
	return perform_driver_method(driver, method, opts)
end

local function poller_is_current(provider_id, driver)
	local rec = state.pollers and state.pollers[provider_id] or nil
	return rec ~= nil and rec.driver == driver and state.drivers[provider_id] == driver
end

local function emit_observing_once(provider_id, driver)
	local rec = state.pollers and state.pollers[provider_id] or nil
	if not rec or rec.observing_emitted then return true, nil end
	local ok, err = emit_status_now(provider_id, {
		state = 'observing',
		available = false,
		driver = driver.provider or driver.driver or 'wired-provider',
		polling = true,
	})
	if ok == true then rec.observing_emitted = true end
	return ok, err
end

local function publish_observation(provider_id, snapshot)
	local cache = merge_observation(provider_id, snapshot)
	return emit_snapshot_now(provider_id, cache)
end

local function failure_status_for_plan(plan, result)
	local err = result and result.err or (result and result.status and result.status.err) or 'wired provider observation failed'
	local unavailable = false
	if plan and plan.groups then
		for _, group in ipairs(plan.groups) do
			if group == 'panel' or group == 'snapshot' then unavailable = true end
		end
	else
		unavailable = true
	end
	return {
		state = unavailable and 'unavailable' or 'degraded',
		available = not unavailable,
		err = err,
		poll = plan and plan.name or nil,
		polling = true,
	}
end

local function perform_poll_plan(provider_id, driver, plan)
	if plan.method == 'snapshot' then
		local result = perform_driver_method(driver, 'snapshot', {})
		if result and result.ok == true then return publish_observation(provider_id, result) end
		return emit_status_now(provider_id, failure_status_for_plan(plan, result))
	end

	for _, group in ipairs(plan.groups or {}) do
		if not poller_is_current(provider_id, driver) then return true, nil end
		local result
		if group == 'snapshot' then
			result = perform_driver_method(driver, 'snapshot', {})
		else
			result = perform_driver_method(driver, 'group_observation', { group = group })
		end
		if not poller_is_current(provider_id, driver) then return true, nil end
		if result and result.ok == true then
			local ok, err = publish_observation(provider_id, result)
			if ok ~= true then return nil, err end
		else
			local ok, err = emit_status_now(provider_id, failure_status_for_plan({ name = plan.name, groups = { group } }, result))
			if ok ~= true then return nil, err end
		end
	end
	return true, nil
end

local function poll_loop(provider_id, driver, plan, ready_cond)
	if ready_cond ~= nil then
		fibers.perform(ready_cond:wait_op())
		if not poller_is_current(provider_id, driver) then return end
	end

	local ok, err = emit_observing_once(provider_id, driver)
	if ok ~= true then log('error', { what = 'wired_provider_initial_status_emit_failed', provider = provider_id, err = err }) end

	while poller_is_current(provider_id, driver) do
		local started = runtime.now()
		local ok, err = perform_poll_plan(provider_id, driver, plan)
		if ok ~= true then log('error', { what = 'wired_provider_poll_emit_failed', provider = provider_id, poll = plan.name, err = err }) end
		local elapsed = runtime.now() - started
		fibers.perform(sleep.sleep_op(max(0, plan.interval_s - elapsed)))
	end
end

local function cancel_pollers(reason)
	local pollers = state.pollers or {}
	state.pollers = {}
	for _, rec in pairs(pollers) do
		if rec and rec.scope then rec.scope:cancel(reason or 'wired provider poller cancelled') end
	end
end

local function cancel_provider_poller(provider_id, reason)
	local rec = state.pollers and state.pollers[provider_id] or nil
	if not rec then return end
	state.pollers[provider_id] = nil
	if rec.scope then rec.scope:cancel(reason or 'wired provider poller cancelled') end
end

local function spawn_provider_poller(provider_id, driver, poll_plan, ready_cond)
	if not state.scope then return nil, 'wired manager scope not started' end
	cancel_provider_poller(provider_id, 'wired provider poller replaced')
	local poll_scope, scope_err = state.scope:child()
	if not poll_scope then return nil, scope_err or 'wired provider poller scope create failed' end

	local rec = {
		scope = poll_scope,
		driver = driver,
		poll_plan = poll_plan,
		ready_cond = ready_cond,
		observing_emitted = false,
	}
	state.pollers[provider_id] = rec
	poll_scope:finally(function ()
		if state.pollers and state.pollers[provider_id] == rec then state.pollers[provider_id] = nil end
	end)

	for _, plan in ipairs(poll_plan or {}) do
		local ok, err = poll_scope:spawn(function () poll_loop(provider_id, driver, plan, ready_cond) end)
		if not ok then
			if state.pollers[provider_id] == rec then state.pollers[provider_id] = nil end
			poll_scope:cancel(tostring(err or 'wired provider poller spawn failed'))
			return nil, err or 'wired provider poller spawn failed'
		end
	end
	return true, nil
end

local function handle_request(provider_id, req)
	local verb = req and req.verb
	local opts = req and req.opts or {}
	local result
	if verb == 'snapshot' or verb == 'watch' or verb == 'apply_attachments' or verb == 'set_poe' or verb == 'bounce' then
		result = driver_result(provider_id, verb, opts)
	else
		result = { ok = false, err = 'unsupported wired-provider verb: ' .. tostring(verb) }
	end
	if result and result.ok == true and (verb == 'snapshot' or verb == 'watch') then
		emit_snapshot_now(provider_id, result)
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

local function stop_drivers(reason)
	for _, driver in pairs(state.drivers or {}) do
		if driver and type(driver.terminate) == 'function' then driver:terminate(reason or 'reconfigured') end
	end
	state.drivers = {}
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

local function reconcile_device_caps(provider_ids)
	local new_sig = list_signature(provider_ids)
	local old_sig = list_signature(state.provider_ids)
	if new_sig == old_sig then return true, nil, nil end

	if state.device_registered then
		local ok, err = fibers.perform(device_event_op('removed', {}))
		if ok == false or ok == nil then return nil, err or 'wired device remove event failed' end
		state.device_registered = false
	end

	close_control_channels()
	state.provider_ids = {}

	if #provider_ids == 0 then return true, nil, nil end

	local caps = make_caps(provider_ids)
	spawn_control_loops(provider_ids)
	local ready_cond = cond.new()
	local ok, err = fibers.perform(device_event_op('added', caps, ready_cond))
	if ok == false or ok == nil then
		close_control_channels()
		return nil, err or 'wired device add event failed'
	end

	state.provider_ids = provider_ids
	state.device_registered = true
	return true, nil, ready_cond
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
		state.drivers = {}
		state.provider_ids = {}
		state.pollers = {}
		state.observations = {}
		state.device_registered = false

		child:finally(function (_, status, primary) M.terminate(primary or status or 'wired manager closed') end)
		state.started = true
		log('info', { what = 'wired_manager_started' })
		return op.always(true, nil)
	end)
end


local function terminate_prepared(prepared, reason)
	for _, rec in pairs(prepared or {}) do
		local driver = rec and rec.driver
		if driver and type(driver.terminate) == 'function' then driver:terminate(reason or 'discarded') end
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
		local driver, err = driver_mod.new(driver_config, driver_opts)
		if not driver then
			terminate_prepared(prepared, 'prepare failed')
			return nil, ('wired provider %s create failed: %s'):format(id, tostring(err))
		end
		driver.provider = driver_config.provider
		prepared[id] = { driver = driver, poll_plan = poll_plan }
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

			cancel_pollers('reconfigured')
			stop_drivers('reconfigured')
			state.observations = {}
			local ok, cerr, caps_ready_cond = reconcile_device_caps(provider_ids)
			if ok ~= true then
				terminate_prepared(prepared, 'capability reconcile failed')
				return false, cerr
			end

			state.drivers = {}
			for i = 1, #provider_ids do
				local id = provider_ids[i]
				state.drivers[id] = prepared[id].driver
			end

			for i = 1, #provider_ids do
				local id = provider_ids[i]
				local rec = prepared[id]
				local spawned, spawn_err = spawn_provider_poller(id, rec.driver, rec.poll_plan, caps_ready_cond)
				if spawned ~= true then
					cancel_pollers('poller spawn failed')
					stop_drivers('poller spawn failed')
					return false, ('wired provider %s poller failed: %s'):format(id, tostring(spawn_err))
				end
			end
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
	cancel_pollers(reason or 'terminated')
	stop_drivers(reason or 'terminated')
	close_control_channels()
	state.provider_ids = {}
	state.pollers = {}
	state.observations = {}
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
}

return M
