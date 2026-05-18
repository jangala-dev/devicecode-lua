-- services/hal/managers/wired.lua
-- Strict op-only HAL manager for semantic wired-provider capabilities.
--
-- Provider capabilities are derived from HAL configuration.  The manager
-- deliberately keeps wired-provider capabilities raw at the HAL boundary; the
-- Device service curates them into public cap/wired-provider/... surfaces.

local fibers = require 'fibers'
local op = require 'fibers.op'
local channel = require 'fibers.channel'

local strict = require 'services.hal.support.strict_manager'
local hal_types = require 'services.hal.types.core'
local cap_types = require 'services.hal.types.capabilities'
local driver_mod = require 'services.hal.drivers.wired'

local M = strict.api_table()

local state = {
	started = false,
	scope = nil,
	logger = nil,
	conn = nil,
	dev_ev_ch = nil,
	cap_emit_ch = nil,
	drivers = {},
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

local function list_signature(list)
	return table.concat(list or {}, '\0')
end

local function emit_state(class, id, key, payload)
	local ev = assert(hal_types.new.Emit(class, id, 'state', key, payload))
	return state.cap_emit_ch:put_op(ev):wrap(function () return true, nil end)
end

local function emit_snapshot_now(provider_id, snapshot)
	local status = snapshot.status or {
		state = 'available',
		available = snapshot.ok == true,
	}
	local ok, err = fibers.perform(emit_state('wired-provider', provider_id, 'status', status))
	if ok == false or ok == nil then return nil, err end
	ok, err = fibers.perform(emit_state('wired-provider', provider_id, 'surfaces', { surfaces = snapshot.surfaces or {} }))
	if ok == false or ok == nil then return nil, err end
	ok, err = fibers.perform(emit_state('wired-provider', provider_id, 'topology', snapshot.topology or {}))
	if ok == false or ok == nil then return nil, err end
	return true, nil
end

local function driver_result(provider_id, method, opts)
	local driver = state.drivers[provider_id]
	if not driver then return { ok = false, err = 'wired provider not configured', code = 'not_configured' } end
	local opname = tostring(method) .. '_op'
	local fn = driver[opname]
	if type(fn) ~= 'function' then return { ok = false, err = 'wired driver missing ' .. opname } end
	local ok, driver_op = pcall(function () return fn(driver, opts or {}) end)
	if not ok then return { ok = false, err = tostring(driver_op) } end
	if type(driver_op) ~= 'table' then return { ok = false, err = opname .. ' did not return an Op' } end
	local ok2, result = pcall(function () return fibers.perform(driver_op) end)
	if not ok2 then return { ok = false, err = tostring(result) } end
	if type(result) == 'table' then return result end
	return { ok = result == true, result = result }
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

local function device_event_op(event_type, caps)
	local ev = assert(hal_types.new.DeviceEvent(event_type, 'wired', 'main', {
		source = 'host',
		source_id = 'wired',
		manager = 'wired',
	}, caps or {}))
	return state.dev_ev_ch:put_op(ev):wrap(function () return true, nil end)
end

local function close_control_channels()
	for _, ch in pairs(state.controls or {}) do
		if ch and type(ch.close) == 'function' then ch:close('reconfigured') end
	end
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
	local ids, seen = {}, {}

	if type(providers) == 'table' then
		local keys = sorted_keys(providers)
		for i = 1, #keys do
			local key = tostring(keys[i])
			local rec = providers[key]
			if type(rec) ~= 'table' then return nil, ('wired provider %s must be a table'):format(key) end
			local id = rec.id or key
				if type(id) ~= 'string' or id == '' then
					return nil, ('wired provider %s id must be a non-empty string'):format(key)
				end
			if seen[id] then return nil, ('duplicate wired provider id %s'):format(id) end
			seen[id] = true
			ids[#ids + 1] = id
		end
	else
		-- Compatibility for early local configs; new configs should use providers={...}.
		if type(config.cm5_local) == 'table' then ids[#ids + 1] = config.cm5_local.id or 'cm5-local-wired' end
		if type(config.switch_main) == 'table' then ids[#ids + 1] = config.switch_main.id or 'switch-main' end
		if type(config.switch) == 'table' then ids[#ids + 1] = config.switch.id or 'switch-main' end
	end

	table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
	return ids, nil
end

local function configured_provider(config, provider_id)
	config = config or {}
	local providers = config.providers
	if type(providers) == 'table' then
		for key, rec in pairs(providers) do
			if type(rec) == 'table' and (rec.id or key) == provider_id then return rec end
		end
		return nil
	end
	if provider_id == (config.cm5_local and config.cm5_local.id or 'cm5-local-wired') then return config.cm5_local end
	if provider_id == (config.switch_main and config.switch_main.id or 'switch-main') then return config.switch_main end
	if provider_id == (config.switch and config.switch.id or 'switch-main') then return config.switch end
	return nil
end

local function reconcile_device_caps(provider_ids)
	local new_sig = list_signature(provider_ids)
	local old_sig = list_signature(state.provider_ids)
	if new_sig == old_sig then return true, nil end

	if state.device_registered then
		local ok, err = fibers.perform(device_event_op('removed', {}))
		if ok == false or ok == nil then return nil, err or 'wired device remove event failed' end
		state.device_registered = false
	end

	close_control_channels()
	state.provider_ids = {}

	if #provider_ids == 0 then return true, nil end

	local caps = make_caps(provider_ids)
	spawn_control_loops(provider_ids)
	local ok, err = fibers.perform(device_event_op('added', caps))
	if ok == false or ok == nil then
		close_control_channels()
		return nil, err or 'wired device add event failed'
	end

	state.provider_ids = provider_ids
	state.device_registered = true
	return true, nil
end

function M.start_op(logger, dev_ev_ch, cap_emit_ch, conn)
	return op.guard(function ()
		if state.started then return op.always(true, nil) end
		local parent = fibers.current_scope()
		local child, cerr = parent:child()
		if not child then return op.always(false, cerr or 'wired manager scope create failed') end

		state.scope = child
		state.logger = logger
		state.conn = conn
		state.dev_ev_ch = dev_ev_ch
		state.cap_emit_ch = cap_emit_ch
		state.controls = {}
		state.drivers = {}
		state.provider_ids = {}
		state.device_registered = false

		child:finally(function (_, status, primary) M.terminate(primary or status or 'wired manager closed') end)
		state.started = true
		log('info', { what = 'wired_manager_started' })
		return op.always(true, nil)
	end)
end

function M.apply_config_op(config)
	return op.guard(function ()
		if not state.started then return op.always(false, 'wired manager not started') end
		return fibers.run_scope_op(function ()
			local provider_ids, perr = normalise_provider_ids(config or {})
			if not provider_ids then return false, perr end

			stop_drivers('reconfigured')
			local ok, cerr = reconcile_device_caps(provider_ids)
			if ok ~= true then return false, cerr end

			for i = 1, #provider_ids do
				local id = provider_ids[i]
				local pcfg = configured_provider(config or {}, id)
				if not pcfg then
					local eok, eerr = emit_snapshot_now(id, {
						status = { state = 'not_configured', available = false },
						surfaces = {},
						topology = {},
					})
					if eok ~= true then return false, eerr or 'wired provider status emit failed' end
				else
					local driver_config = {}
					for k, v in pairs(pcfg) do driver_config[k] = v end
					driver_config.id = driver_config.id or id
					local driver, err = driver_mod.new(driver_config, {
						logger = state.logger,
						cap_emit_ch = state.cap_emit_ch,
						conn = state.conn,
					})
					if not driver then
						return false, ('wired provider %s create failed: %s'):format(id, tostring(err))
					end
					state.drivers[id] = driver
					local result = driver_result(id, 'snapshot', {})
					if result.ok == true then
						local eok, eerr = emit_snapshot_now(id, result)
						if eok ~= true then return false, eerr or 'wired provider emit failed' end
					else
						local eok, eerr = emit_snapshot_now(id, {
							status = { state = 'unavailable', available = false, err = result.err },
							surfaces = {},
							topology = {},
						})
						if eok ~= true then return false, eerr or 'wired provider status emit failed' end
					end
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
	stop_drivers(reason or 'terminated')
	close_control_channels()
	state.provider_ids = {}
	state.device_registered = false
	if state.scope then local scope = state.scope; state.scope = nil; scope:cancel(reason or 'terminated') end
	state.started = false
	state.logger = nil
	state.conn = nil
	state.dev_ev_ch = nil
	state.cap_emit_ch = nil
	return true, nil
end

function M.fault_op()
	return strict.fault_op_for_state(state)
end

M._test = {
	normalise_provider_ids = normalise_provider_ids,
}

return M
