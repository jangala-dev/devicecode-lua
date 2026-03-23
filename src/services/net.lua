-- services/net.lua
--
-- Net service.

local fibers   = require 'fibers'
local runtime  = require 'fibers.runtime'
local sleep    = require 'fibers.sleep'

local perform      = fibers.perform
local named_choice = fibers.named_choice

local base         = require 'devicecode.service_base'
local compiler_adapter = require 'services.net.compiler_adapter'
local model_mod    = require 'services.net.model'
local control      = require 'services.net.control'

local M = {}

local function now()
	return runtime.now()
end

local function min_deadline(...)
	local best = model_mod.inf()
	for i = 1, select('#', ...) do
		local v = select(i, ...)
		if type(v) == 'number' and v < best then best = v end
	end
	return best
end

local function compile_initial_model(svc, payload)
	if type(payload) ~= 'table' or type(payload.rev) ~= 'number' or type(payload.data) ~= 'table' then
		svc:obs_log('warn', { what = 'bad_config_payload', kind = type(payload) })
		return nil
	end

	local rev = math.floor(payload.rev)
	local gen = 1

	local bundle, diag = compiler_adapter.compile_bundle_from_config(payload.data, rev, gen)
	if not bundle then
		svc:obs_log('error', { what = 'compile_failed', diag = diag, rev = rev })
		return nil
	end

	svc:obs_event('config_update', {
		ts  = svc:now(),
		at  = svc:wall(),
		rev = bundle.rev,
		gen = bundle.gen,
	})

	return model_mod.build_runtime_model(bundle)
end

local function compile_updated_bundle(svc, model, payload)
	if type(payload) ~= 'table' or type(payload.rev) ~= 'number' or type(payload.data) ~= 'table' then
		svc:obs_log('warn', { what = 'bad_config_payload', kind = type(payload) })
		return nil
	end

	local rev = math.floor(payload.rev)
	local cur_rev = model and model.bundle and model.bundle.rev or 0
	if rev <= cur_rev then
		return nil
	end

	local next_gen = ((model and model.bundle and model.bundle.gen) or 0) + 1
	local bundle, diag = compiler_adapter.compile_bundle_from_config(payload.data, rev, next_gen)
	if not bundle then
		svc:obs_log('error', { what = 'compile_failed', diag = diag, rev = rev })
		return nil
	end

	svc:obs_event('config_update', {
		ts  = svc:now(),
		at  = svc:wall(),
		rev = bundle.rev,
		gen = bundle.gen,
	})

	return bundle
end

function M.start(conn, opts)
	opts = opts or {}
	local svc = base.new(conn, { name = opts.name or 'net', env = opts.env })

	local timings = opts.timings or {}

	local function numopt(name, default)
		local v = timings[name]
		return (type(v) == 'number') and v or default
	end

	local hal_wait_timeout_s = numopt('hal_wait_timeout_s', 60)
	local hal_wait_tick_s    = numopt('hal_wait_tick_s', 10)

	svc:status('starting')
	svc:obs_log('info', { what = 'start_entered' })

	local hal_announce, herr = svc:wait_for_hal({
		timeout = hal_wait_timeout_s,
		tick    = hal_wait_tick_s,
	})

	if not hal_announce then
		local err = herr or 'no hal available'
		svc:status('failed', { reason = err })
		svc:obs_log('error', { what = 'start_failed', err = tostring(err) })
		error(('net: failed to discover HAL: %s'):format(tostring(err)), 0)
	end

	svc:status('starting', { hal_backend = hal_announce.backend })
	svc:obs_event('ready', { hal_backend = hal_announce.backend })

	local sub_cfg = conn:subscribe({ 'config', 'net' }, { queue_len = 10, full = 'drop_oldest' })

	local model = nil

	-- Wait for the first successfully compiled config.
	while model == nil do
		local msg, err = perform(sub_cfg:recv_op())
		if not msg then
			svc:status('failed', { reason = err })
			svc:obs_log('error', { what = 'config_subscription_ended', err = tostring(err) })
			error(('net: config subscription ended before initial config: %s'):format(tostring(err)), 0)
		end

		model = compile_initial_model(svc, msg.payload)
	end

	while true do
		local tnow = now()

		local next_timer_at = min_deadline(
			model.structural.dirty and model.structural.next_apply_at or model_mod.inf(),
			model.inventory.dirty  and model.inventory.next_at        or model_mod.inf(),
			model.probing.dirty    and model.probing.next_at          or model_mod.inf(),
			model.counters.dirty   and model.counters.next_at         or model_mod.inf(),
			model.control.dirty    and model.control.next_at          or model_mod.inf(),
			model.persist.dirty    and model.persist.next_at          or model_mod.inf()
		)

		local arms = {
			cfg = sub_cfg:recv_op(),
		}

		if next_timer_at < model_mod.inf() then
			local dt = next_timer_at - tnow
			if dt < 0 then dt = 0 end
			arms.timer = sleep.sleep_op(dt):wrap(function() return true end)
		end

		local which, a, b = perform(named_choice(arms))

		if which == 'cfg' then
			local msg, err = a, b
			if not msg then
				svc:status('failed', { reason = err })
				svc:obs_log('error', { what = 'config_subscription_ended', err = tostring(err) })
				error(('net: config subscription ended: %s'):format(tostring(err)), 0)
			end

			local bundle = compile_updated_bundle(svc, model, msg.payload)
			if bundle then
				model_mod.merge_bundle_into_model(model, bundle)
			end
		else
			local tick_now = now()

			if model.structural.dirty and tick_now >= model.structural.next_apply_at then
				svc:obs_event('apply_begin', {
					gen = model.bundle.gen,
					rev = model.bundle.rev,
				})

				local ok = control.run_structural_apply(svc, model)
				if ok then
					svc:status('running', {
						hal_backend      = hal_announce.backend,
						last_applied_rev = model.bundle.rev,
						last_applied_gen = model.bundle.gen,
					})
					model_mod.mark_inventory_dirty(model, now())
					model_mod.mark_probe_dirty(model, now())
					model_mod.mark_counter_dirty(model, now())
					model_mod.mark_control_dirty(model, now())
				end
			end

			if model.inventory.dirty and tick_now >= model.inventory.next_at then
				control.refresh_inventory(svc, model, model_mod.mark_control_dirty)
			end

			if model.probing.dirty and tick_now >= model.probing.next_at then
				control.run_probe_round(svc, model, model_mod.mark_control_dirty)
			end

			if model.counters.dirty and tick_now >= model.counters.next_at then
				control.run_counter_sample(svc, model, model_mod.mark_control_dirty)
			end

			if model.control.dirty and tick_now >= model.control.next_at then
				control.run_control_pass(conn, svc, model, model_mod.mark_persist_dirty)
			end

			if model.persist.dirty and tick_now >= model.persist.next_at then
				control.run_persist_pass(svc, model)
			end
		end
	end
end

return M
