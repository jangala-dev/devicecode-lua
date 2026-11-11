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

local function table_has_entries(t)
	if type(t) ~= 'table' then return false end
	return next(t) ~= nil
end

local function backhaul_ready(snapshot)
	local bh = snapshot and snapshot.backhaul or nil
	return type(bh) == 'table' and table_has_entries(bh.uplinks)
end

local function enrich_backhaul_status(payload, state, uplink)
	local snap = state and state.model and state.model:snapshot() or nil
	local status = wan_policy.uplink_observed_status(snap, uplink)
	if type(status) == 'table' then
		payload.backhaul_state = status.state
		payload.backhaul_usable = status.usable
		payload.backhaul_interface = status.interface
		payload.backhaul_ifname = status.ifname
		payload.backhaul_source = status.source
	else
		payload.backhaul_status = 'missing'
	end
	if not backhaul_ready(snap) then payload.backhaul = 'missing' end
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

local function enrich_measurement(payload, state, uplink)
	local snap = state and state.model and state.model:snapshot() or nil
	local measurement = snap and wan_policy.measurement(snap, uplink) or nil
	if type(measurement) == 'table' then
		payload.measurement_key = measurement.key
		payload.address = measurement.address
		payload.address_family = measurement.address_family
	end
	return payload
end

local function report_speedtest_skip(state, reason, trigger, uplink, generation)
	local payload = enrich_measurement(enrich_backhaul_status(speedtest_skip_payload(reason, trigger, uplink, generation), state, uplink), state, uplink)
	payload.what = 'speedtest_skipped'
	obs_log(state, 'debug', payload)
	obs_event(state, 'speedtest_skipped',
		enrich_measurement(enrich_backhaul_status(speedtest_skip_payload(reason, trigger, uplink, generation), state, uplink), state, uplink))
end

local function mark_speedtest_skipped(state, uplink, generation, reason)
	state.model:update(function(s)
		s.wan_runtime = s.wan_runtime or { uplinks = {}, speedtests = {}, live_weights = {} }
		s.wan_runtime.speedtests = s.wan_runtime.speedtests or {}
		local id = uplink.uplink_id
		local rec = s.wan_runtime.speedtests[id] or { uplink_id = id }
		local measurement = wan_policy.measurement(s, uplink)
		local active = state.active_speedtests and state.active_speedtests[id]
		local awaiting_observation = reason == 'waiting_for_observation'
			and rec.state == 'running' and active
			and active.generation == generation and rec.generation == generation
			and active.speedtest_id == rec.id
		if reason == 'running' or awaiting_observation then
			-- Observation updates must not make an active download eligible again.
			-- Preserve its state until the original completion arrives.
		elseif (reason == 'fresh_same_path' or reason == 'fresh_weak_path') and rec.last_success then
			rec.state = 'ok'
			rec.ok = true
			if reason == 'fresh_weak_path' and type(measurement) == 'table' then
				rec.last_success.measurement_key = measurement.key
				rec.last_success.measurement = model_mod.deep_copy(measurement)
				rec.last_success_key = measurement.key
			end
		else
			rec.state = 'skipped'
			rec.ok = false
		end
		rec.last_skip_generation = generation
		rec.last_skip_reason = reason
		rec.interface = uplink.request and uplink.request.interface or rec.interface
		rec.device = uplink.request and uplink.request.device or rec.device
		if type(measurement) == 'table' then
			rec.current_measurement_key = measurement.key
			rec.current_measurement = model_mod.deep_copy(measurement)
		end
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
	local measurement, merr = wan_policy.measurement(snap, uplink)
	if not measurement then return nil, merr or 'speedtest_measurement_key_unavailable' end

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
		local previous = s.wan_runtime.speedtests[uplink_id]
		local same_path_failure = type(previous) == 'table'
			and (previous.measurement_key == measurement.key or previous.current_measurement_key == measurement.key)
		s.wan_runtime.speedtests[uplink_id] = {
			state = 'running',
			generation = generation,
			id = id,
			uplink_id = uplink_id,
			-- Whether this path carried traffic when tested; a standby result shows
			-- what is left on the table, an in-use one is measured under load.
			in_use = wan_policy.uplink_in_use(snap, uplink_id),
			interface = uplink.request.interface,
			device = uplink.request.device,
			metric = uplink.request.metric,
			measurement_key = measurement.key,
			measurement = model_mod.deep_copy(measurement),
			failure_count = same_path_failure and (tonumber(previous.failure_count) or 0) or 0,
			last_failure = same_path_failure and model_mod.deep_copy(previous.last_failure) or nil,
			last_success = previous and model_mod.deep_copy(previous.last_success) or nil,
			last_success_mbps = previous and previous.last_success_mbps or nil,
			last_success_at = previous and previous.last_success_at or nil,
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
				rec.state = 'failed'; rec.ok = false; rec.err = tostring(err); rec.last_attempt = { state = 'failed', reason = 'failed_to_start', completed_at = now(state) }
			end
			return s
		end)
		return nil, err
	end
	state.active_speedtests[uplink_id] = { generation = generation, speedtest_id = id, handle = handle }
	return true, nil
end

local start_live_weight_apply

local function apply_weights_if_ready(state, generation)
	if state.active_weight_apply ~= nil then return true, nil end
	for _, active in pairs(state.active_speedtests or {}) do
		if active and active.generation == generation then return true, nil end
	end
	local snap = state.model:snapshot()
	local weights = wan_policy.compute_weights(snap, generation, { now = now(state) })
	if not weights then return true, nil end
	local previous = snap.wan_runtime and snap.wan_runtime.last_weight_apply and snap.wan_runtime.last_weight_apply.members
	if wan_policy.weights_equal(previous, weights) then return true, nil end
	return start_live_weight_apply(state, weights)
end

local function cancel_active_speedtest(state, uplink_id, why)
	local active = state.active_speedtests[uplink_id]
	if active and active.handle and type(active.handle.cancel) == 'function' then
		active.handle:cancel(why)
	end
	state.active_speedtests[uplink_id] = nil
end

local ACTIVE_SCOPE_WEIGHTS_REASON = 'speedtest_scope_active'

-- Why no weights are computed when live weights are off.
local function weights_off_reason(snap)
	if wan_policy.speedtest_scope(snap) == 'active' then return ACTIVE_SCOPE_WEIGHTS_REASON end
	return 'live_weights_disabled'
end

-- Record that mwan3 weights are deliberately left alone.
local function mark_weights_not_applicable(state, generation, reason)
	reason = reason or ACTIVE_SCOPE_WEIGHTS_REASON
	state.model:update(function(s)
		s.wan_runtime = s.wan_runtime or { uplinks = {}, speedtests = {}, live_weights = {} }
		local lw = s.wan_runtime.live_weights
		if type(lw) == 'table' and lw.state == 'not_applicable' and lw.reason == reason
			and lw.generation == generation then
			return s
		end
		s.wan_runtime.live_weights = {
			state = 'not_applicable', reason = reason, generation = generation,
			updated_at = now(state),
		}
		return s
	end)
end

-- Remember which uplink the active-scope results describe, so a later change
-- of active uplink (failover or failback) is noticed.
local function acknowledge_active_uplink(state, uplink_id, reason)
	state.model:update(function(s)
		s.wan_runtime = s.wan_runtime or { uplinks = {}, speedtests = {}, live_weights = {} }
		s.wan_runtime.active_speedtest = { uplink_id = uplink_id, reason = reason, acknowledged_at = now(state) }
		return s
	end)
end

local function acknowledge_if_fresh(state, current, uplink, due_reason)
	if due_reason ~= 'fresh_same_path' and due_reason ~= 'fresh_weak_path' then return end
	local acked = current.wan_runtime and current.wan_runtime.active_speedtest
	if type(acked) ~= 'table' or acked.uplink_id ~= uplink.uplink_id then
		acknowledge_active_uplink(state, uplink.uplink_id, due_reason)
	end
end

-- The member carrying most traffic, which is re-tested when traffic moves to it.
local function is_lead_uplink(snap, uplink)
	local active = wan_policy.active_uplink(snap)
	return active ~= nil and active.status == 'uplink' and active.uplink_id == uplink.uplink_id
end

local function skip_uplink(state, snap, uplink, generation, trigger, online_reason)
	local skip_reason
	if wan_policy.uplink_online(snap, uplink) then
		skip_reason = online_reason
	elseif wan_policy.uplink_observed_status(snap, uplink) == nil then
		skip_reason = 'waiting_for_observation'
	else
		skip_reason = 'not_online'
	end
	mark_speedtest_skipped(state, uplink, generation, skip_reason)
	report_speedtest_skip(state, skip_reason, trigger, uplink, generation)
end

local function reconcile_active_scope(state, reason, snap, uplinks, generation)
	local active = wan_policy.active_uplink(snap)
	local active_id = active and active.status == 'uplink' and active.uplink_id or nil
	local target
	for i = 1, #uplinks do
		local uplink = uplinks[i]
		if uplink.uplink_id == active_id then
			target = uplink
		else
			-- Standby uplinks are never tested: that spends data on SIMs not in use.
			cancel_active_speedtest(state, uplink.uplink_id, 'not_active_uplink')
			skip_uplink(state, snap, uplink, generation, reason, 'not_active_uplink')
		end
	end
	mark_weights_not_applicable(state, generation)
	if not target then return true, nil end

	if not wan_policy.uplink_online(snap, target) then
		if wan_policy.uplink_observed_status(snap, target) ~= nil then
			cancel_active_speedtest(state, target.uplink_id, 'uplink_offline')
		end
		skip_uplink(state, snap, target, generation, reason, 'not_online')
		return true, nil
	end

	local current = state.model:snapshot()
	local due, due_reason = wan_policy.active_speedtest_due(current, target,
		{ generation = generation, now = now(state) })
	if due then
		if next(state.active_speedtests) == nil then
			local ok, err = start_speedtest_for_uplink(state, target)
			if ok ~= true then return nil, err end
			acknowledge_active_uplink(state, target.uplink_id, due_reason)
		end
		return true, nil
	end
	acknowledge_if_fresh(state, current, target, due_reason)
	mark_speedtest_skipped(state, target, generation, due_reason or 'not_due')
	report_speedtest_skip(state, due_reason or 'not_due', reason, target, generation)
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

	if wan_policy.speedtest_scope(snap) == 'active' then
		return reconcile_active_scope(state, reason, snap, uplinks, generation)
	end

	-- Release tests on uplinks observed offline before choosing the next one to launch.
	for i = 1, #uplinks do
		local uplink = uplinks[i]
		if not wan_policy.uplink_online(snap, uplink) and wan_policy.uplink_observed_status(snap, uplink) ~= nil then
			local active = state.active_speedtests[uplink.uplink_id]
			if active and active.handle and type(active.handle.cancel) == 'function' then
				active.handle:cancel('uplink_offline')
			end
			state.active_speedtests[uplink.uplink_id] = nil
		end
	end

	-- Test the backhaul carrying traffic first, so a failover is measured promptly.
	local ordered = {}
	for i = 1, #uplinks do
		if is_lead_uplink(snap, uplinks[i]) then
			table.insert(ordered, 1, uplinks[i])
		else
			ordered[#ordered + 1] = uplinks[i]
		end
	end
	uplinks = ordered

	local speedtest_pending = false
	for i = 1, #uplinks do
		local uplink = uplinks[i]
		local observed_status = wan_policy.uplink_observed_status(snap, uplink)
		local online = wan_policy.uplink_online(snap, uplink)
		if not online then
			local skip_reason = observed_status == nil and 'waiting_for_observation' or 'not_online'
			mark_speedtest_skipped(state, uplink, generation, skip_reason)
			report_speedtest_skip(state, skip_reason, reason, uplink, generation)
		else
			local current = state.model:snapshot()
			local lead = is_lead_uplink(snap, uplink)
			local due_fn = lead and wan_policy.active_speedtest_due or wan_policy.speedtest_due
			local due, due_reason = due_fn(current, uplink, { generation = generation, now = now(state) })
			if due then
				speedtest_pending = true
				-- The HAL runs speed tests serially, but each caller deadline starts
				-- at launch. Launch one at a time; completion reconciles the next.
				if next(state.active_speedtests) == nil then
					local ok, err = start_speedtest_for_uplink(state, uplink)
					if ok ~= true then return nil, err end
					if lead then acknowledge_active_uplink(state, uplink.uplink_id, due_reason) end
				end
			else
				if lead then acknowledge_if_fresh(state, current, uplink, due_reason) end
				if due_reason == 'running' then speedtest_pending = true end
				mark_speedtest_skipped(state, uplink, generation, due_reason or 'not_due')
				report_speedtest_skip(state, due_reason or 'not_due', reason, uplink, generation)
			end
		end
	end
	if not wan_policy.live_weights_enabled(snap) then
		mark_weights_not_applicable(state, generation, weights_off_reason(snap))
		return true, nil
	end
	if not speedtest_pending then return apply_weights_if_ready(state, generation) end
	return true, nil
end

M.start_speedtests = M.reconcile_speedtests

function start_live_weight_apply(state, members)
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
		local completed_at = now(state)
		rec.generation = ev.generation
		rec.id = ev.speedtest_id
		rec.ok = result.ok == true
		rec.err = result.err
		rec.interface = result.interface or (work_result.request and work_result.request.interface) or rec.interface
		rec.device = result.device or (work_result.request and work_result.request.device) or rec.device
		rec.metric = rec.metric or (work_result.request and work_result.request.metric) or 1
		rec.completed_at = completed_at
		local mbps = tonumber(result.mbps or result.peak_mbps)
		if result.ok == true and mbps ~= nil then
			rec.state = 'ok'
			rec.failure_count = 0
			rec.retry_after = nil
			rec.retry_delay_s = nil
			rec.last_failure = nil
			rec.peak_mbps = mbps -- compatibility
			rec.last_success_mbps = mbps -- compatibility
			rec.last_success_at = completed_at
			rec.last_success_key = rec.measurement_key
			rec.last_success = {
				mbps = mbps,
				lower_bound = result.lower_bound,
				estimator = result.estimator,
				bytes = result.bytes,
				data_mib = result.data_mib,
				duration_s = result.duration_s,
				completed_at = completed_at,
				measurement_key = rec.measurement_key,
				measurement = model_mod.deep_copy(rec.measurement),
			}

		else
			local reason = result.code or result.err or 'speedtest_failed'
			rec.state = 'failed'
			rec.ok = false
			rec.err = reason
			rec.failure_count = (tonumber(rec.failure_count) or 0) + 1
			rec.retry_delay_s = wan_policy.speedtest_retry_delay_s(s, rec)
			rec.retry_after = completed_at + rec.retry_delay_s
			rec.last_failure = {
				state = 'failed',
				reason = reason,
				completed_at = completed_at,
				failure_count = rec.failure_count,
				retry_delay_s = rec.retry_delay_s,
				retry_after = rec.retry_after,
			}
			rec.last_attempt = rec.last_failure -- compatibility
			if rec.last_success_mbps ~= nil then rec.peak_mbps = rec.last_success_mbps end
		end
		rec.data_mib = result.data_mib
		rec.duration_s = result.duration_s
		rec.bytes = result.bytes
		rec.setup_s = result.setup_s
		rec.total_duration_s = result.total_duration_s
		rec.stop_reason = result.stop_reason
		rec.estimator = result.estimator
		rec.lower_bound = result.lower_bound
		rec.error_detail = result.err
		s.wan_runtime.speedtests[ev.uplink_id] = rec
		s.stats.speedtests_completed = (s.stats.speedtests_completed or 0) + 1
		return s
	end)
	local snap = state.model:snapshot()
	if not wan_policy.live_weights_enabled(snap) then
		mark_weights_not_applicable(state, ev.generation, weights_off_reason(snap))
		return true, nil
	end
	local weights, werr = wan_policy.compute_weights(snap, ev.generation, { now = now(state) })
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
