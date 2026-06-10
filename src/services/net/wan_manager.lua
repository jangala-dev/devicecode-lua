-- services/net/wan_manager.lua
-- Coordinator-facing WAN runtime manager.

local wan_runtime = require 'services.net.wan_runtime'
local wan_policy = require 'services.net.wan_policy'
local stale = require 'services.net.stale'
local model_mod = require 'services.net.model'

local M = {}

local function now(state)
	return state.now and state.now() or require('fibers').now()
end

local function obs_log(state, level, payload)
	local svc = state and state.svc
	if svc and type(svc.obs_log) == 'function' then svc:obs_log(level, payload) end
end

local function obs_event(state, kind, payload)
	local svc = state and state.svc
	if svc and type(svc.obs_event) == 'function' then
		payload = payload or {}
		payload.kind = payload.kind or kind
		svc:obs_event(kind, payload)
	end
end

local function observed_multiwan(snapshot)
	local observed = snapshot and snapshot.observed or nil
	local mw = observed and observed.snapshot and observed.snapshot.multiwan or nil
	if type(mw) ~= 'table' then mw = observed and observed.multiwan or nil end
	return type(mw) == 'table' and mw or nil
end

local function table_has_entries(t)
	if type(t) ~= 'table' then return false end
	return next(t) ~= nil
end

local function observed_multiwan_ready(snapshot)
	local mw = observed_multiwan(snapshot)
	if not mw then return false end
	return table_has_entries(mw.interfaces) or table_has_entries(mw.interfaces_by_semantic)
end

local function enrich_observed_status(payload, state, uplink)
	local snap = state and state.model and state.model:snapshot() or nil
	local mw = observed_multiwan(snap)
	local status = wan_policy.uplink_observed_status(snap, uplink)
	if type(status) == 'table' then
		payload.observed_state = status.state or status.mwan3_status
		payload.observed_online = status.online
		payload.observed_usable = status.usable
		payload.observed_up = status.up
		payload.observed_interface = status.interface
		payload.observed_ifname = status.ifname
	else
		payload.observed_status = 'missing'
	end
	if not mw then payload.observed_multiwan = 'missing' end
	return payload
end

local function speedtest_skip_payload(reason, trigger, uplink, generation)
	return {
		reason = reason,
		trigger = trigger,
		generation = generation,
		uplink_id = uplink and uplink.uplink_id or nil,
		interface = uplink and uplink.request and uplink.request.interface or nil,
		device = uplink and uplink.request and uplink.request.device or nil,
	}
end

local function report_speedtest_skip(state, reason, trigger, uplink, generation)
	local payload = enrich_observed_status(speedtest_skip_payload(reason, trigger, uplink, generation), state, uplink)
	payload.what = 'speedtest_skipped'
	obs_log(state, 'debug', payload)
	obs_event(state, 'speedtest_skipped',
		enrich_observed_status(speedtest_skip_payload(reason, trigger, uplink, generation), state, uplink))
end

local function mark_speedtest_skipped(state, uplink, generation, reason)
	state.model:update(function(s)
		s.wan_runtime = s.wan_runtime or { uplinks = {}, speedtests = {}, live_weights = {} }
		s.wan_runtime.speedtests = s.wan_runtime.speedtests or {}
		local id = uplink.uplink_id
		local rec = s.wan_runtime.speedtests[id] or { uplink_id = id, state = 'skipped' }
		if rec.state == nil then rec.state = 'skipped' end
		rec.last_skip_generation = generation
		rec.last_skip_reason = reason
		rec.interface = uplink.request and uplink.request.interface or rec.interface
		rec.device = uplink.request and uplink.request.device or rec.device
		rec.updated_at = now(state)
		s.wan_runtime.speedtests[id] = rec
		return s
	end)
end

function M.cancel(state, reason)
	for _, rec in pairs(state.active_speedtests or {}) do
		if rec.handle and type(rec.handle.cancel) == 'function' then rec.handle:cancel(reason or 'wan_runtime_cancelled') end
	end
	state.active_speedtests = {}
	if state.active_weight_apply and state.active_weight_apply.handle and type(state.active_weight_apply.handle.cancel) == 'function' then
		state.active_weight_apply.handle:cancel(reason or 'wan_runtime_cancelled')
	end
	state.active_weight_apply = nil
	return true, nil
end

local function start_speedtest_for_uplink(state, uplink)
	if not state.hal or type(state.hal.speedtest_op) ~= 'function' then return true, nil end
	local snap = state.model:snapshot()
	if not wan_policy.speedtest_enabled(snap) then return true, nil end
	local generation = state.current_generation and state.current_generation.generation or snap.generation
	if type(generation) ~= 'number' or generation <= 0 then return true, nil end

	local uplink_id = uplink.uplink_id
	local prev = snap.wan_runtime and snap.wan_runtime.speedtests and snap.wan_runtime.speedtests[uplink_id]
	if prev and prev.state == 'running' and prev.generation == generation then return true, nil end

	local id = state.next_speedtest_id
	state.next_speedtest_id = id + 1
	state.model:update(function(s)
		s.wan_runtime = s.wan_runtime or { uplinks = {}, speedtests = {}, live_weights = {} }
		s.wan_runtime.generation = generation
		s.wan_runtime.uplinks[uplink_id] = {
			uplink_id = uplink_id,
			interface = uplink.request.interface,
			device = uplink.request.device,
			metric = uplink.request.metric,
			updated_at = now(state),
		}
		s.wan_runtime.speedtests[uplink_id] = {
			state = 'running',
			generation = generation,
			id = id,
			uplink_id = uplink_id,
			interface = uplink.request.interface,
			device = uplink.request.device,
			metric = uplink.request.metric,
			started_at = now(state),
		}
		s.stats.speedtests_started = (s.stats.speedtests_started or 0) + 1
		return s
	end)
	if state.mark_dirty then state.mark_dirty('domain', 'wan_runtime') end

	local handle, err = wan_runtime.start_speedtest {
		lifetime_scope = state.scope,
		reaper_scope = state.scope,
		report_scope = state.scope,
		service_id = state.service_id,
		generation = generation,
		speedtest_id = id,
		uplink_id = uplink_id,
		request = uplink.request,
		hal = state.hal,
		done_tx = state.done_tx,
	}
	if not handle then
		state.model:update(function(s)
			local rec = s.wan_runtime and s.wan_runtime.speedtests and s.wan_runtime.speedtests[uplink_id]
			if rec then
				rec.state = 'failed_to_start'; rec.err = tostring(err)
			end
			return s
		end)
		return nil, err
	end
	state.active_speedtests[uplink_id] = { generation = generation, speedtest_id = id, handle = handle }
	return true, nil
end

function M.reconcile_speedtests(state, reason)
	local snap = state.model:snapshot()
	if not wan_policy.speedtest_enabled(snap) then
		obs_log(state, 'debug', {
			what = 'speedtests_skipped',
			reason = 'speedtests_disabled',
			trigger = reason
		})
		return true, nil
	end
	local generation = state.current_generation and state.current_generation.generation or snap.generation
	if type(generation) ~= 'number' or generation <= 0 then
		obs_log(state, 'debug', {
			what = 'speedtests_skipped',
			reason = 'invalid_generation',
			trigger = reason,
			generation = generation
		})
		return true, nil
	end

	local uplinks = wan_policy.collect_uplinks(snap)
	if #uplinks == 0 then
		state.model:update(function(s)
			s.wan_runtime = s.wan_runtime or { uplinks = {}, speedtests = {}, live_weights = {} }
			s.wan_runtime.live_weights = { state = 'not_applicable', reason = 'no_wan_uplinks', generation = generation }
			return s
		end)
		return true, nil
	end

	state.model:update(function(s)
		s.wan_runtime = s.wan_runtime or { uplinks = {}, speedtests = {}, live_weights = {} }
		s.wan_runtime.generation = s.wan_runtime.generation or generation
		s.wan_runtime.last_reconcile_reason = reason
		s.wan_runtime.last_reconcile_at = now(state)
		return s
	end)

	for i = 1, #uplinks do
		local uplink = uplinks[i]
		local observed_status = wan_policy.uplink_observed_status(snap, uplink)
		local online = wan_policy.uplink_online(snap, uplink)
		if not online then
			local skip_reason = 'not_online'
			if observed_status == nil and not observed_multiwan_ready(snap) then
				skip_reason = 'waiting_for_observation'
			else
				local active = state.active_speedtests[uplink.uplink_id]
				if active and active.handle and type(active.handle.cancel) == 'function' then
					active.handle:cancel('uplink_offline')
				end
				state.active_speedtests[uplink.uplink_id] = nil
			end
			mark_speedtest_skipped(state, uplink, generation, skip_reason)
			report_speedtest_skip(state, skip_reason, reason, uplink, generation)
		else
			local due, due_reason = wan_policy.speedtest_due(state.model:snapshot(), uplink,
				{ generation = generation, now = now(state) })
			if due then
				local ok, err = start_speedtest_for_uplink(state, uplink)
				if ok ~= true then return nil, err end
			else
				mark_speedtest_skipped(state, uplink, generation, due_reason or 'not_due')
				report_speedtest_skip(state, due_reason or 'not_due', reason, uplink, generation)
			end
		end
	end
	return true, nil
end

M.start_speedtests = M.reconcile_speedtests

local function start_live_weight_apply(state, members)
	if not members or #members == 0 or not state.hal or type(state.hal.apply_live_weights_op) ~= 'function' then
		return
			true, nil
	end
	local snap = state.model:snapshot()
	local generation = state.current_generation and state.current_generation.generation or snap.generation
	if type(generation) ~= 'number' or generation <= 0 then return true, nil end

	if state.active_weight_apply and state.active_weight_apply.handle and state.active_weight_apply.handle.cancel then
		state.active_weight_apply.handle:cancel('live_weight_apply_superseded')
	end

	local id = state.next_weight_apply_id
	state.next_weight_apply_id = id + 1
	state.active_weight_apply = { generation = generation, weight_apply_id = id }
	state.model:update(function(s)
		s.wan_runtime = s.wan_runtime or { uplinks = {}, speedtests = {}, live_weights = {} }
		s.wan_runtime.live_weights = {
			state = 'running',
			generation = generation,
			id = id,
			policy = wan_policy.live_weight_policy(snap),
			members = model_mod.deep_copy(members),
			started_at = now(state),
		}
		return s
	end)

	local handle, err = wan_runtime.start_live_weights {
		lifetime_scope = state.scope,
		reaper_scope = state.scope,
		report_scope = state.scope,
		service_id = state.service_id,
		generation = generation,
		weight_apply_id = id,
		members = members,
		policy = wan_policy.live_weight_policy(snap),
		persist = true,
		hal = state.hal,
		done_tx = state.done_tx,
	}
	if not handle then
		state.active_weight_apply = nil
		return nil, err
	end
	state.active_weight_apply.handle = handle
	return true, nil
end

function M.handle_speedtest_done(state, ev)
	if not stale.speedtest_current(state, ev) then
		stale.reject(state, ev)
		return true, 'stale'
	end
	state.active_speedtests[ev.uplink_id] = nil
	local work_result = ev.result or {}
	local result = work_result.result or work_result
	state.model:update(function(s)
		s.wan_runtime = s.wan_runtime or { uplinks = {}, speedtests = {}, live_weights = {} }
		local rec = s.wan_runtime.speedtests[ev.uplink_id] or { uplink_id = ev.uplink_id, id = ev.speedtest_id }
		rec.state = 'done'
		rec.generation = ev.generation
		rec.id = ev.speedtest_id
		rec.ok = result.ok == true
		rec.err = result.err
		rec.interface = result.interface or (work_result.request and work_result.request.interface) or rec.interface
		rec.device = result.device or (work_result.request and work_result.request.device) or rec.device
		rec.metric = rec.metric or (work_result.request and work_result.request.metric) or 1
		if result.ok == true and result.peak_mbps ~= nil then
			rec.peak_mbps = result.peak_mbps
			rec.last_success_mbps = result.peak_mbps
			rec.last_success_at = now(state)
		elseif rec.last_success_mbps ~= nil then
			rec.peak_mbps = rec.last_success_mbps
		end
		rec.data_mib = result.data_mib
		rec.duration_s = result.duration_s
		rec.completed_at = now(state)
		if rec.ok ~= true then rec.retry_after = now(state) + 60 end
		s.wan_runtime.speedtests[ev.uplink_id] = rec
		s.stats.speedtests_completed = (s.stats.speedtests_completed or 0) + 1
		return s
	end)
	local snap = state.model:snapshot()
	local weights, werr = wan_policy.compute_weights(snap, ev.generation)
	if not weights then
		state.model:update(function(s)
			s.wan_runtime = s.wan_runtime or { uplinks = {}, speedtests = {}, live_weights = {} }
			s.wan_runtime.live_weights = {
				state = 'skipped',
				generation = ev.generation,
				reason = werr or 'no_weights',
				updated_at =
					now(state)
			}
			return s
		end)
		return true, nil
	end
	local previous = snap.wan_runtime and snap.wan_runtime.last_weight_apply and
		snap.wan_runtime.last_weight_apply.members
	if wan_policy.weights_equal(previous, weights) then return true, nil end
	return start_live_weight_apply(state, weights)
end

function M.handle_live_weights_done(state, ev)
	if not stale.live_weights_current(state, ev) then
		stale.reject(state, ev)
		return true, 'stale'
	end
	state.active_weight_apply = nil
	local work_result = ev.result or {}
	local result = work_result.result or work_result
	state.model:update(function(s)
		s.wan_runtime = s.wan_runtime or { uplinks = {}, speedtests = {}, live_weights = {} }
		s.wan_runtime.live_weights = {
			state = result.ok == true and 'applied' or 'failed',
			generation = ev.generation,
			id = ev.weight_apply_id,
			members = work_result.members or (work_result.request and work_result.request.members),
			result = model_mod.deep_copy(result),
			updated_at = now(state),
		}
		if result.ok == true then
			s.wan_runtime.last_weight_apply = {
				generation = ev.generation,
				id = ev.weight_apply_id,
				members = model_mod
					.deep_copy(work_result.members or (work_result.request and work_result.request.members) or {}),
				updated_at =
					now(state)
			}
		end
		s.stats.live_weight_applies = (s.stats.live_weight_applies or 0) + 1
		return s
	end)
	return true, nil
end

return M
