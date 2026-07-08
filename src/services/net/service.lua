-- services/net/service.lua
-- NET service coordinator.
--
-- NET owns product-level network intent and publication.  HAL owns host/network
-- mechanics.  The coordinator has one suspending control point; blocking work is
-- admitted through scoped components.

local fibers = require 'fibers'
local sleep = require 'fibers.sleep'
local mailbox = require 'fibers.mailbox'

local service_base = require 'devicecode.service_base'
local config_watch = require 'devicecode.support.config_watch'
local queue = require 'devicecode.support.queue'

local model_mod = require 'services.net.model'
local config_mod = require 'services.net.config'
local events = require 'services.net.events'
local publisher = require 'services.net.publisher'
local generation_mod = require 'services.net.generation'
local apply_runtime = require 'services.net.apply_runtime'
local stale = require 'services.net.stale'
local hal_client_mod = require 'services.net.hal_client'
local cap_deps_mod = require 'devicecode.support.capability_dependencies'
local observer_manager = require 'services.net.observer_manager'
local wan_manager = require 'services.net.wan_manager'
local metrics = require 'services.net.metrics'
local drift = require 'services.net.drift'
local backpressure = require 'services.net.backpressure'
local gsm_uplink_watch = require 'services.net.gsm_uplink_watch'
local intent_realiser = require 'services.net.intent_realiser'
local backhaul_model = require 'services.net.backhaul_model'

local perform = fibers.perform

local M = {}

local function now() return fibers.now() end

local function elapsed_ms(t0)
	if not t0 then return nil end
	return math.floor(((now() - t0) * 1000) + 0.5)
end

local function new_service_id(name)
	return tostring(name or 'net')
end

local function obs_log(svc, level, payload)
	if svc and type(svc.obs_log) == 'function' then svc:obs_log(level, payload) end
end

local function obs_event(svc, kind, payload)
	if svc and type(svc.obs_event) == 'function' then
		payload = payload or {}
		payload.kind = payload.kind or kind
		svc:obs_event(kind, payload)
	end
end

local function set_status(svc, state, fields)
	if svc and type(svc.status) == 'function' then svc:status(state, fields) end
end

local function mark_all_dirty(state)
	publisher.mark_all(state.dirty)
end

local function mark_domain_dirty(state, name)
	publisher.mark_domain(state.dirty, name)
end

local function mark_interface_dirty(state, id)
	if id ~= nil then publisher.mark_interface(state.dirty, tostring(id)) end
end

local function mark_apply_dirty(state)
	publisher.mark_apply(state.dirty)
end

local function mark_summary_dirty(state)
	publisher.mark_summary(state.dirty)
end

local project_dependencies

local function publish_snapshot(state)
	if not state.conn then
		publisher.clear_dirty(state.dirty)
		return true, nil
	end
	return publisher.publish_dirty_now(state.conn, state.model:snapshot(), state.dirty, state.published)
end

local function speedtests_blocked_by_apply(state)
	if state.active_apply ~= nil or state.pending_intent ~= nil then return true end
	local snap = state.model and state.model:snapshot() or nil
	local apply_state = snap and snap.apply and snap.apply.state or nil
	return apply_state == 'running' or apply_state == 'waiting_for_hal'
end

local function reconcile_speedtests_if_ready(state, reason)
	if speedtests_blocked_by_apply(state) then
		local snap = state.model and state.model:snapshot() or nil
		obs_log(state.svc, 'debug', {
			what = 'speedtests_deferred',
			reason = reason,
			apply_state = snap and snap.apply and snap.apply.state or nil,
		})
		return true, nil
	end
	return wan_manager.reconcile_speedtests(state, reason)
end


local function sorted_keys(t)
	local keys = {}
	for k in pairs(t or {}) do keys[#keys + 1] = tostring(k) end
	table.sort(keys)
	return keys
end

local function latest_successful_speedtest(snapshot)
	local tests = snapshot and snapshot.wan_runtime and snapshot.wan_runtime.speedtests or {}
	local best = nil
	for id, rec in pairs(tests or {}) do
		if type(rec) == 'table' and rec.ok == true and rec.peak_mbps ~= nil then
			if not best or (tonumber(rec.completed_at) or 0) > (tonumber(best.completed_at) or 0) then
				best = { id = id, rec = rec, completed_at = tonumber(rec.completed_at) or 0 }
			end
		end
	end
	return best
end

local function log_net_summary(state, reason)
	if not state.svc or not state.model then return end
	local snap = state.model:snapshot()
	local parts = {}
	local wan_iface = snap.interfaces and snap.interfaces.wan or nil
	local endpoint = type(wan_iface) == 'table' and type(wan_iface.endpoint) == 'table' and wan_iface.endpoint or {}
	local latest = latest_successful_speedtest(snap)
	local wan_state = (wan_iface and wan_iface.state) or nil
	if not wan_state and latest and tostring(latest.id) == 'wan' and latest.rec and latest.rec.ok == true then wan_state = 'online' end
	if not wan_state and endpoint.device then wan_state = 'configured' end
	if wan_state then parts[#parts + 1] = 'wan=' .. tostring(wan_state) end
	if endpoint.device or (latest and latest.rec and latest.rec.device) then parts[#parts + 1] = 'device=' .. tostring(endpoint.device or latest.rec.device) end
	if endpoint.address or endpoint.ipaddr then parts[#parts + 1] = 'addr=' .. tostring(endpoint.address or endpoint.ipaddr) end
	if latest then parts[#parts + 1] = string.format('speedtest=%s:%.1fMbps', tostring(latest.id), tonumber(latest.rec.peak_mbps) or 0) end
	local last_apply = snap.wan_runtime and snap.wan_runtime.last_weight_apply or nil
	if last_apply and type(last_apply.detail) == 'table' then
		local detail = last_apply.detail
		local eff, skipped = {}, {}
		for _, m in ipairs(detail.members or {}) do eff[#eff + 1] = tostring(m.semantic_interface or m.interface or m.id or '?') end
		for _, m in ipairs(detail.skipped_members or {}) do skipped[#skipped + 1] = tostring(m.semantic_interface or m.interface or m.id or '?') end
		if #eff > 0 then parts[#parts + 1] = 'effective=' .. table.concat(eff, ',') end
		if #skipped > 0 then parts[#parts + 1] = 'skipped=' .. table.concat(skipped, ',') end
	end
	local backhaul = snap.backhaul and snap.backhaul.uplinks or {}
	local backhaul_parts = {}
	for _, uplink_id in ipairs(sorted_keys(backhaul)) do
		local rec = backhaul[uplink_id]
		if type(rec) == 'table' then
			backhaul_parts[#backhaul_parts + 1] = tostring(uplink_id) .. '=' .. tostring(rec.state or 'unknown')
		end
	end
	if #backhaul_parts > 0 then parts[#parts + 1] = 'backhaul=' .. table.concat(backhaul_parts, ',') end
	local summary = 'net summary ' .. table.concat(parts, ' ')
	local tnow = now()
	if state.operator_net_summary_key == summary and (tnow - (state.operator_net_summary_at or 0)) < 600 then return end
	state.operator_net_summary_key = summary
	state.operator_net_summary_at = tnow
	obs_log(state.svc, 'info', { what = 'net_summary', summary = summary, reason = reason })
end


local function backhaul_uplinks(backhaul)
	local uplinks = type(backhaul) == 'table' and backhaul.uplinks or nil
	return type(uplinks) == 'table' and uplinks or {}
end

local function log_mwan_backhaul_transitions(state, before, after, trigger)
	if not state.svc then return end
	local prev = backhaul_uplinks(before)
	local next_uplinks = backhaul_uplinks(after)
	for _, uplink_id in ipairs(sorted_keys(next_uplinks)) do
		local rec = next_uplinks[uplink_id]
		if type(rec) == 'table' then
			local source = type(rec.status_source) == 'table' and rec.status_source or rec.source
			local tool = type(source) == 'table' and source.tool or nil
			local prev_rec = prev[uplink_id]
			local prev_state = type(prev_rec) == 'table' and prev_rec.state or nil
			local state_now = rec.state
			if (state_now == 'online' or state_now == 'offline') and state_now ~= prev_state and (tool == nil or tool == 'mwan3') then
				obs_log(state.svc, 'info', {
					what = state_now == 'online' and 'mwan_member_online' or 'mwan_member_offline',
					summary = string.format('mwan member %s %s interface=%s ifname=%s', tostring(uplink_id), tostring(state_now), tostring(rec.interface or '?'), tostring(rec.ifname or '?')),
					uplink_id = tostring(uplink_id),
					interface = rec.interface,
					ifname = rec.ifname,
					state = state_now,
					usable = rec.usable == true,
					previous_state = prev_state,
					subject = trigger and trigger.subject or nil,
					source = trigger and trigger.source or nil,
				})
			end
		end
	end
end

local function set_model_state(state, service_state, reason)
	state.model:update(function (s)
		s.state = service_state
		s.ready = service_state == 'running'
		s.reason = reason
		return project_dependencies(state, s)
	end)
	mark_summary_dirty(state)
	return publish_snapshot(state)
end

local function dependency_status(state, key)
	return state.cap_deps:status(key)
end

local function dependency_effectively_available(state, key)
	return state.cap_deps:available(key)
end

project_dependencies = function(state, s)
	s.dependencies = state.cap_deps:snapshot()
	return s
end

local function set_pending_apply_projection(s, intent, reason)
	s.pending = s.pending or {}
	if intent == nil then
		s.pending.network_apply = nil
		return s
	end
	s.pending.network_apply = {
		kind = 'network_apply',
		generation = intent.generation,
		rev = intent.rev,
		reason = reason or 'network_config_unavailable',
	}
	return s
end

local function normalise_config_event(state, ev)
	local generation = state.next_generation
	local intent, err = config_mod.normalise(ev.payload, { rev = ev.rev, generation = generation })
	if not intent then return nil, err end
	return intent, nil
end

local function cancel_active_runtime(state, reason)
	wan_manager.cancel(state, reason or 'generation_replaced')
	return true, nil
end

local function cancel_active_generation(state, reason)
	cancel_active_runtime(state, reason or 'generation_replaced')
	local active = state.current_generation
	if not active then return true, nil end
	generation_mod.cancel(active, reason or 'generation_replaced')
	state.current_generation = nil
	state.active_apply = nil
	state.pending_intent = nil
	state.pending_apply_reason = nil
	return true, nil
end


local function backhaul_for_interface(backhaul, uplink_id, iface_id)
	local uplinks = backhaul and backhaul.uplinks or nil
	if type(uplinks) ~= 'table' then return nil end
	local direct = uplinks[tostring(uplink_id)]
	if type(direct) == 'table' then return direct end
	for id, rec in pairs(uplinks) do
		if type(rec) == 'table' and (rec.interface == iface_id or rec.id == iface_id or id == iface_id) then
			return rec
		end
	end
	return nil
end

local function apply_backhaul_to_interfaces(s)
	local members = s and s.wan and s.wan.configured_members or {}
	local interfaces = s and s.interfaces or nil
	if type(interfaces) ~= 'table' then return s end
	for uplink_id, member in pairs(members or {}) do
		if type(member) == 'table' and member.enabled ~= false and member.disabled ~= true then
			local iface_id = member.interface or uplink_id
			local iface = interfaces[iface_id]
			local bh = backhaul_for_interface(s.backhaul, uplink_id, iface_id)
			if type(iface) == 'table' and type(bh) == 'table' then
				-- mwan3/backhaul is the semantic authority for WAN reachability.
				-- Interface config and speedtests enrich this record; they must not
				-- make an mwan3-online uplink appear offline to consumers.
				iface.state = bh.state
				iface.status = bh.state
				iface.online = bh.state == 'online' and bh.usable == true
				iface.usable = bh.usable == true
				iface.backhaul = {
					state = bh.state,
					usable = bh.usable == true,
					ifname = bh.ifname,
					path_address = model_mod.deep_copy(bh.path_address),
					source = model_mod.deep_copy(bh.source),
					observed_at = bh.observed_at,
				}
			end
		end
	end
	return s
end

local function mark_wan_member_interfaces_dirty(state)
	local snap = state and state.model and state.model:snapshot() or nil
	local members = snap and snap.wan and snap.wan.configured_members or {}
	for uplink_id, member in pairs(members or {}) do
		if type(member) == 'table' and member.enabled ~= false and member.disabled ~= true then
			mark_interface_dirty(state, member.interface or uplink_id)
		end
	end
end

local function carry_forward_wan_runtime(previous, intent, generation)
	local out = { generation = generation, uplinks = {}, speedtests = {}, live_weights = { state = 'idle', generation = generation } }
	if type(previous) ~= 'table' then return out end
	local members = intent and intent.wan and intent.wan.members or {}
	for uplink_id, member in pairs(members or {}) do
		if type(member) == 'table' and member.enabled ~= false and member.disabled ~= true then
			local rec = previous.speedtests and previous.speedtests[tostring(uplink_id)] or nil
			if type(rec) == 'table' then
				local kept = model_mod.deep_copy(rec)
				if kept.state == 'running' then
					kept.state = kept.last_success and 'ok' or 'skipped'
					kept.ok = kept.last_success ~= nil
					kept.last_skip_reason = kept.last_skip_reason or 'generation_replaced'
				end
				out.speedtests[tostring(uplink_id)] = kept
			end
		end
	end
	out.last_weight_apply = model_mod.deep_copy(previous.last_weight_apply)
	return out
end

local function copy_wan_catalogue_and_realisation(configured_wan, realised_wan)
	local wan = model_mod.deep_copy(configured_wan or {})
	wan.configured_members = model_mod.deep_copy((configured_wan and configured_wan.members) or {})
	wan.realised_members = model_mod.deep_copy((realised_wan and realised_wan.members) or {})
	wan.members = nil
	return wan
end

local function copy_intent_to_model(s, apply_intent, configured_intent)
	configured_intent = configured_intent or apply_intent
	local generation = configured_intent.generation or apply_intent.generation
	s.generation = generation
	s.config = {
		rev = configured_intent.rev,
		schema = configured_intent.schema,
		config_schema = configured_intent.config_schema,
		version = configured_intent.version,
	}
	s.intent = s.intent or {}
	s.intent.generation = generation
	s.intent.realised_generation = apply_intent.generation
	s.segments = apply_intent.segments or {}
	s.vlan_policy = apply_intent.vlan_policy or {}
	s.policies = apply_intent.policies or {}
	s.interfaces = apply_intent.interfaces or {}
	s.addressing = apply_intent.addressing or {}
	s.dns = apply_intent.dns or {}
	s.dhcp = apply_intent.dhcp or {}
	s.firewall = apply_intent.firewall or {}
	s.routing = apply_intent.routing or {}
	-- Keep the product-level WAN member catalogue stable in the public NET
	-- model.  The OpenWrt/HAL apply intent may legitimately omit GSM-backed
	-- members until a Linux ifname exists; that volatility must not remove
	-- state/net/backhaul.uplinks or local-UI cards.  The realised set is kept
	-- separately for diagnostics and apply/runtime policy that needs it.
	s.wan = copy_wan_catalogue_and_realisation(configured_intent.wan, apply_intent.wan)
	s.sources = s.sources or { gsm_uplinks = {} }
	s.backhaul = backhaul_model.reduce(s, { now = now() })
	apply_backhaul_to_interfaces(s)
	s.wan_runtime = carry_forward_wan_runtime(s.wan_runtime, configured_intent, generation)
	s.vpn = apply_intent.vpn or {}
	s.diagnostics = apply_intent.diagnostics or {}
	return s
end


local function realised_sources(state)
	local snap = state.model and state.model:snapshot() or {}
	return snap.sources or { gsm_uplinks = {} }
end

local function realise_intent(state, intent)
	return intent_realiser.realise(intent, realised_sources(state))
end

local function realised_fingerprint(state, intent)
	return intent_realiser.realised_fingerprint(intent, realised_sources(state))
end

local function accept_pending_intent(state, intent, reason)
	reason = reason or 'network_config_unavailable'
	local apply_intent = realise_intent(state, intent)
	local gen = generation_mod.new(apply_intent.generation, apply_intent, reason, { now = now() })
	gen.state = 'waiting_for_hal'
	gen.reason = reason
	gen.apply = { state = 'waiting_for_hal', reason = reason }

	state.current_generation = gen
	state.active_apply = nil
	state.pending_intent = intent
	state.pending_apply_reason = reason
	state.base_intent = intent
	state.last_realised_source_fingerprint = realised_fingerprint(state, intent)

	state.model:update(function (s)
		copy_intent_to_model(s, apply_intent, intent)
		s.state = 'waiting_for_hal'
		s.ready = false
		s.reason = reason
		s.intent = s.intent or {}
		s.intent.active = generation_mod.snapshot(gen)
		set_pending_apply_projection(s, intent, reason)
		s.apply = {
			state = 'waiting_for_hal',
			generation = intent.generation,
			apply_id = nil,
			started_at = nil,
			last_applied_rev = s.apply and s.apply.last_applied_rev or nil,
			last_error = reason,
			last_result = nil,
		}
		s.stats.config_updates = (s.stats.config_updates or 0) + 1
		return project_dependencies(state, s)
	end)
	mark_all_dirty(state)
	return true, nil
end

local function start_apply_for_intent(state, intent, reason)
	local apply_intent = realise_intent(state, intent)
	state.base_intent = intent
	state.last_realised_source_fingerprint = realised_fingerprint(state, intent)
	local generation = apply_intent.generation
	local apply_id = state.next_apply_id
	state.next_apply_id = apply_id + 1

	local gen = state.current_generation
	if not gen or gen.generation ~= generation then
		gen = generation_mod.new(generation, apply_intent, reason, { now = now() })
	end
	generation_mod.start_apply(gen, apply_id, { now = now() })
	state.current_generation = gen
	state.active_apply = { generation = generation, apply_id = apply_id, rev = intent.rev }
	state.pending_intent = nil
	state.pending_apply_reason = nil

	state.model:update(function (s)
		copy_intent_to_model(s, apply_intent, intent)
		s.state = 'applying'
		s.ready = false
		s.reason = nil
		s.intent = s.intent or {}
		s.intent.active = generation_mod.snapshot(gen)
		set_pending_apply_projection(s, nil)
		s.apply = {
			state = 'running',
			generation = generation,
			apply_id = apply_id,
			started_at = now(),
			last_applied_rev = s.apply and s.apply.last_applied_rev or nil,
			last_error = nil,
			last_result = nil,
		}
		s.stats.apply_started = (s.stats.apply_started or 0) + 1
		return project_dependencies(state, s)
	end)
	mark_all_dirty(state)
	local ok_pub, pub_err = publish_snapshot(state)
	if ok_pub ~= true then return nil, pub_err end

	obs_event(state.svc, 'apply_started', { generation = generation, apply_id = apply_id, rev = apply_intent.rev, reason = reason })
	obs_log(state.svc, 'info', {
		what = 'apply_started',
		summary = string.format('network apply %s started generation=%s reason=%s', tostring(apply_id), tostring(generation), tostring(reason or 'unknown')),
		generation = generation,
		apply_id = apply_id,
		reason = reason,
	})

	local handle, err = apply_runtime.start_apply {
		lifetime_scope = state.scope,
		reaper_scope = state.scope,
		report_scope = state.scope,
		service_id = state.service_id,
		generation = generation,
		apply_id = apply_id,
		intent = apply_intent,
		hal = state.hal,
		done_tx = state.done_tx,
	}
	if not handle then
		generation_mod.mark_failed(gen, err or 'apply_start_failed', nil, { now = now() })
		state.active_apply = nil
		state.model:update(function (s)
			s.intent.active = generation_mod.snapshot(gen)
			s.apply.state = 'failed_to_start'
			s.apply.last_error = tostring(err or 'apply_start_failed')
			return project_dependencies(state, s)
		end)
		mark_apply_dirty(state)
		return nil, err
	end

	gen.apply_handle = handle
	return true, nil
end

local function reconcile_apply_admission(state, reason)
	if state.active_apply ~= nil then return true, nil end
	local intent = state.pending_intent
	if not intent then return true, nil end
	if not dependency_effectively_available(state, 'network_config') then
		local wait_reason = state.pending_apply_reason or 'network_config_unavailable'
		set_status(state.svc, 'waiting_for_hal', { reason = wait_reason })
		return publish_snapshot(state)
	end
	return start_apply_for_intent(state, intent, reason or state.pending_apply_reason or 'network_config_available')
end

local function handle_config_changed(state, ev)
	local intent, err = normalise_config_event(state, ev)
	if not intent then
		obs_log(state.svc, 'warn', { what = 'config_rejected', err = tostring(err) })
		state.model:update(function (s)
			s.state = 'degraded'
			s.ready = false
			s.reason = tostring(err)
			s.intent = s.intent or {}
			s.intent.last_rejected = { rev = ev.rev, err = tostring(err), rejected_at = now() }
			return project_dependencies(state, s)
		end)
		mark_summary_dirty(state)
		return publish_snapshot(state)
	end

	state.next_generation = intent.generation + 1
	state.base_intent = intent
	cancel_active_generation(state, 'config_replaced')
	obs_event(state.svc, 'config_accepted', {
		rev = intent.rev,
		generation = intent.generation,
		segments = intent.stats and intent.stats.segments or nil,
		interfaces = intent.stats and intent.stats.interfaces or nil,
	})

	local ok, apply_err = accept_pending_intent(state, intent, 'network_config_unavailable')
	if ok ~= true then return nil, apply_err end

	ok, apply_err = reconcile_apply_admission(state, 'config_changed')
	if ok ~= true then
		state.model:update(function (s)
			s.state = 'degraded'
			s.ready = false
			s.reason = tostring(apply_err or 'apply_start_failed')
			return project_dependencies(state, s)
		end)
		mark_summary_dirty(state)
		publish_snapshot(state)
		return nil, apply_err or 'net apply start failed'
	end
	return true, nil
end

local function classify_network_config_apply_failure(state, result)
	local failure = result and result.result or result
	return state.cap_deps:classify_call_failure('network_config', failure)
end

local function return_apply_to_pending(state, result, reason)
	reason = reason or 'network_config_unavailable'
	local gen = state.current_generation
	local apply_intent = gen and gen.intent or nil
	local intent = state.base_intent or apply_intent
	state.active_apply = nil
	if not intent then return set_model_state(state, 'waiting_for_hal', reason) end

	gen.state = 'waiting_for_hal'
	gen.reason = reason
	gen.apply = gen.apply or {}
	gen.apply.state = 'waiting_for_hal'
	gen.apply.reason = reason
	gen.apply.result = result

	state.pending_intent = intent
	state.pending_apply_reason = reason

	state.model:update(function (s)
		s.state = 'waiting_for_hal'
		s.ready = false
		s.reason = reason
		s.intent = s.intent or {}
		s.intent.active = generation_mod.snapshot(gen)
		set_pending_apply_projection(s, intent, reason)
		s.apply = s.apply or {}
		s.apply.state = 'waiting_for_hal'
		s.apply.completed_at = now()
		s.apply.last_result = result and result.result or result
		s.apply.last_error = reason
		s.stats.apply_completed = (s.stats.apply_completed or 0) + 1
		return project_dependencies(state, s)
	end)
	mark_apply_dirty(state)
	set_status(state.svc, 'waiting_for_hal', { reason = reason })
	obs_event(state.svc, 'apply_deferred', { generation = gen.generation, reason = reason })
	return publish_snapshot(state)
end

local function handle_apply_done(state, ev)
	if not stale.apply_current(state, ev) then
		stale.reject(state, ev)
		mark_summary_dirty(state)
		return publish_snapshot(state)
	end

	local result = ev.result or {}
	local apply_ok = ev.status == 'ok' and result.ok == true
	local reason = nil
	if not apply_ok then reason = ev.primary or (result.result and result.result.err) or 'apply_failed' end

	if not apply_ok then
		local failure_class = classify_network_config_apply_failure(state, result)
		if failure_class == 'route_missing' then
			return return_apply_to_pending(state, result, 'network_config_unavailable')
		end
	end

	state.active_apply = nil
	if state.current_generation then
		if apply_ok then generation_mod.mark_applied(state.current_generation, result, { now = now() })
		else generation_mod.mark_failed(state.current_generation, reason, result, { now = now() }) end
	end

	state.model:update(function (s)
		s.state = apply_ok and 'running' or 'degraded'
		s.ready = apply_ok
		s.reason = reason
		s.intent = s.intent or {}
		s.intent.active = generation_mod.snapshot(state.current_generation)
		set_pending_apply_projection(s, nil)
		s.apply.state = apply_ok and 'applied' or 'failed'
		s.apply.completed_at = now()
		s.apply.last_result = result.result
		s.apply.last_error = reason
		if apply_ok then s.apply.last_applied_rev = result.intent_rev or (s.config and s.config.rev) end
		s.stats.apply_completed = (s.stats.apply_completed or 0) + 1
		return project_dependencies(state, s)
	end)

	mark_apply_dirty(state)
	set_status(state.svc, apply_ok and 'running' or 'degraded', reason and { reason = reason } or nil)
	local started_at = state.model:snapshot().apply and state.model:snapshot().apply.started_at or nil
	local apply_elapsed_ms = elapsed_ms(started_at)
	obs_event(state.svc, 'apply_completed', { generation = ev.generation, apply_id = ev.apply_id, ok = apply_ok, reason = reason, elapsed_ms = apply_elapsed_ms })
	obs_log(state.svc, apply_ok and 'info' or 'warn', {
		what = apply_ok and 'apply_completed' or 'apply_failed',
		summary = apply_ok
			and string.format('network apply %s completed in %.1fs', tostring(ev.apply_id), (apply_elapsed_ms or 0) / 1000)
			or string.format('network apply %s failed: %s', tostring(ev.apply_id), tostring(reason or 'unknown')),
		generation = ev.generation,
		apply_id = ev.apply_id,
		ok = apply_ok,
		reason = reason,
		elapsed_ms = apply_elapsed_ms,
	})

	local ok_pub, pub_err = publish_snapshot(state)
	if ok_pub ~= true then return nil, pub_err end
	if apply_ok then
		local ok, err = wan_manager.reconcile_speedtests(state, 'apply_done')
		mark_domain_dirty(state, 'wan_runtime')
		publish_snapshot(state)
		return ok, err
	end
	return true, nil
end

local function merge_observation(state, s, observed_event)
	local observed = observed_event and observed_event.observed or nil
	s.observed = s.observed or { interfaces = {}, segments = {} }
	s.observed.last_event = observed_event
	s.observed.last_event_at = now()
	s.observed.last_subject = observed_event and observed_event.subject or nil

	if type(observed) == 'table' then
		if type(observed.interfaces) == 'table' then s.observed.interfaces = model_mod.deep_copy(observed.interfaces) end
		if type(observed.segments) == 'table' then s.observed.segments = model_mod.deep_copy(observed.segments) end
		s.observed.snapshot = model_mod.deep_copy(observed)
	elseif observed_event and observed_event.subject and observed_event.subject:match('^interface:') and type(observed_event.interface) == 'table' then
		local id = observed_event.subject:match('^interface:(.+)$')
		if id then s.observed.interfaces[id] = model_mod.deep_copy(observed_event.interface) end
	end

	s.stats.observations = (s.stats.observations or 0) + 1
	s.drift = drift.calculate(s, { now = now })
	s.backhaul = backhaul_model.reduce(s, { now = now() })
	apply_backhaul_to_interfaces(s)
	return project_dependencies(state, s)
end

local function handle_observed_state(state, ev)
	local observed_event = ev and ev.event or nil
	if type(observed_event) ~= 'table' then return true, nil end
	local before = state.model and state.model:snapshot().backhaul or nil
	state.model:update(function (s) return merge_observation(state, s, observed_event) end)
	local after = state.model and state.model:snapshot().backhaul or nil
	log_mwan_backhaul_transitions(state, before, after, observed_event)
	mark_domain_dirty(state, 'observed')
	mark_domain_dirty(state, 'backhaul')
	mark_wan_member_interfaces_dirty(state)
	mark_domain_dirty(state, 'drift')
	obs_event(state.svc, 'network_observed', { subject = observed_event.subject, source = observed_event.source, kind = observed_event.kind })
	local ok, err = reconcile_speedtests_if_ready(state, 'observed_state')
	mark_domain_dirty(state, 'wan_runtime')
	local pub_ok, pub_err = publish_snapshot(state)
	if pub_ok ~= true then return nil, pub_err end
	return ok, err
end

local function handle_gsm_uplink_changed(state, ev)
	if ev.kind == 'gsm_uplink_replay_done' then return true, nil end
	if ev.kind == 'gsm_uplink_unknown' then
		obs_log(state.svc, 'debug', { what = 'gsm_uplink_unknown', event = ev.event })
		return true, nil
	end
	local role = ev.role
	if type(role) ~= 'string' or role == '' then return true, nil end
	local payload = model_mod.deep_copy(ev.payload or {})
	payload.schema = payload.schema or 'devicecode.gsm.uplink/1'
	payload.id = payload.id or role
	payload.role = payload.role or role
	payload.updated_at = now()
	state.model:update(function (s)
		s.sources = s.sources or { gsm_uplinks = {} }
		s.sources.gsm_uplinks = s.sources.gsm_uplinks or {}
		s.sources.gsm_uplinks[role] = payload
		s.backhaul = backhaul_model.reduce(s, { now = now() })
		apply_backhaul_to_interfaces(s)
		s.stats.gsm_uplink_updates = (s.stats.gsm_uplink_updates or 0) + 1
		return project_dependencies(state, s)
	end)
	mark_domain_dirty(state, 'sources')
	mark_domain_dirty(state, 'backhaul')
	mark_wan_member_interfaces_dirty(state)
	mark_summary_dirty(state)
	local ifname = payload.linux and payload.linux.ifname or payload.interface
	obs_event(state.svc, 'gsm_uplink_changed', {
		role = role,
		state = payload.state,
		connected = payload.connected == true,
		ifname = ifname,
	})
	local uplink_key = tostring(role) .. '|' .. tostring(payload.state) .. '|' .. tostring(payload.connected == true) .. '|' .. tostring(ifname or '')
	state._operator_gsm_uplink = state._operator_gsm_uplink or {}
	if state._operator_gsm_uplink[role] ~= uplink_key then
		state._operator_gsm_uplink[role] = uplink_key
		local expected_online = payload.expected_online == true or payload.expected_connected == true
		local level = (payload.connected == true or not expected_online) and 'info' or 'warn'
		obs_log(state.svc, level, {
			what = 'gsm_uplink_changed',
			summary = string.format('cellular uplink %s %s%s%s', tostring(role), tostring(payload.state or (payload.connected and 'connected' or 'disconnected')), ifname and (' ifname=' .. tostring(ifname)) or '', expected_online and ' expected=true' or ''),
			role = role,
			state = payload.state,
			connected = payload.connected == true,
			expected_online = expected_online or nil,
			ifname = ifname,
		})
	end
	local structural_ok, structural_err = true, nil
	if state.base_intent then
		local fp = realised_fingerprint(state, state.base_intent)
		if fp ~= state.last_realised_source_fingerprint then
			local next_intent = model_mod.deep_copy(state.base_intent)
			next_intent.generation = state.next_generation
			state.next_generation = state.next_generation + 1
			state.base_intent = next_intent
			local active_apply = state.active_apply
			if active_apply and state.svc then
				obs_log(state.svc, 'warn', {
					what = 'apply_superseded',
					summary = string.format('network apply %s superseded by generation=%s reason=gsm_uplink_binding_changed', tostring(active_apply.apply_id or '?'), tostring(next_intent.generation)),
					apply_id = active_apply.apply_id,
					generation = active_apply.generation,
					next_generation = next_intent.generation,
					reason = 'gsm_uplink_binding_changed',
				})
			end
			cancel_active_generation(state, 'gsm_uplink_binding_changed')
			structural_ok, structural_err = accept_pending_intent(state, next_intent, 'gsm_uplink_binding_changed')
			if structural_ok == true then structural_ok, structural_err = reconcile_apply_admission(state, 'gsm_uplink_binding_changed') end
		end
	end
	local ok, err = reconcile_speedtests_if_ready(state, 'gsm_uplink_changed')
	mark_domain_dirty(state, 'wan_runtime')
	local pub_ok, pub_err = publish_snapshot(state)
	if pub_ok ~= true then return nil, pub_err end
	if structural_ok ~= true then return nil, structural_err end
	return ok, err
end

local function ensure_observer_started(state, reason)
	if state.observe == false or state.observer ~= nil then return true, nil end
	if not state.hal or type(state.hal.open_observed_subscription) ~= 'function' then return true, nil end
	local observer, err = observer_manager.start {
		lifetime_scope = state.scope,
		reaper_scope = state.scope,
		report_scope = state.scope,
		service_id = state.service_id,
		generation = state.current_generation and state.current_generation.generation or 0,
		hal = state.hal,
		done_tx = state.done_tx,
		queue_len = state.observation_queue_len,
		full = state.observation_full,
		options = state.observation_options,
	}
	if not observer then
		obs_log(state.svc, 'debug', { what = 'network_observation_not_started', reason = reason, err = tostring(err) })
		state.model:update(function (m)
			m.observed.last_error = tostring(err)
			return project_dependencies(state, m)
		end)
		mark_summary_dirty(state)
		mark_domain_dirty(state, 'observed')
		return true, nil
	end
	state.observer = observer
	state.observed_sub = observer:subscription()
	state.model:update(function (m)
		return project_dependencies(state, m)
	end)
	mark_summary_dirty(state)
	return true, nil
end

local function stop_observer(state, reason)
	if state.observer then state.observer:terminate(reason or 'network_state_unavailable') end
	state.observer = nil
	state.observed_sub = nil
	return true, nil
end

local function reconcile_observer_admission(state, reason)
	if dependency_effectively_available(state, 'network_state') then
		return ensure_observer_started(state, reason or 'network_state_available')
	end
	return stop_observer(state, reason or ('network_state_' .. tostring(dependency_status(state, 'network_state'))))
end

local function handle_observation_started(state, ev)
	local work = ev.result or {}
	local result = work.result or work
	local ok = ev.status == 'ok' and work.ok == true and (result.ok == nil or result.ok == true)
	state.model:update(function (m)
		if not ok then m.observed.last_error = result.err or ev.primary or 'observation_start_failed' end
		return project_dependencies(state, m)
	end)
	if not ok then stop_observer(state, 'observation_start_failed') end
	mark_summary_dirty(state)
	mark_domain_dirty(state, 'observed')
	return publish_snapshot(state)
end

local function handle_dependency_status(state, ev)
	local key = ev.key or ev.capability
	local status = key and state.cap_deps:status(key) or ev.status
	state.model:update(function (m)
		return project_dependencies(state, m)
	end)
	mark_summary_dirty(state)
	if key == 'network_state' then
		local ok, err = reconcile_observer_admission(state, 'network_state_' .. tostring(status))
		if ok ~= true then return nil, err end
	elseif key == 'network_config' then
		if dependency_effectively_available(state, 'network_config') then
			local ok, err = reconcile_apply_admission(state, 'network_config_available')
			if ok ~= true then return nil, err end
		end
	end
	return publish_snapshot(state)
end


local function schedule_speedtest_retry(state, uplink_id, generation, delay_s, reason)
	if not state or not state.scope or not state.done_tx then return true, nil end
	if type(uplink_id) ~= 'string' or uplink_id == '' then return true, nil end
	delay_s = tonumber(delay_s) or 10
	if delay_s < 1 then delay_s = 1 end
	state.speedtest_retries = state.speedtest_retries or {}
	local existing = state.speedtest_retries[uplink_id]
	local tnow = now()
	if type(existing) == 'table' and (existing.due_at or 0) > tnow then return true, nil end
	local retry_id = state.next_speedtest_retry_id or 1
	state.next_speedtest_retry_id = retry_id + 1
	state.speedtest_retries[uplink_id] = {
		retry_id = retry_id,
		uplink_id = uplink_id,
		generation = generation,
		due_at = tnow + delay_s,
		reason = reason or 'speedtest_retry',
	}
	local ok, err = state.scope:spawn(function ()
		sleep.sleep(delay_s)
		queue.assert_admit_required(state.done_tx, {
			kind = 'speedtest_retry_due',
			uplink_id = uplink_id,
			generation = generation,
			retry_id = retry_id,
			reason = reason or 'speedtest_retry',
		}, 'net_speedtest_retry_report_failed')
	end)
	if ok ~= true then
		state.speedtest_retries[uplink_id] = nil
		return nil, err or 'speedtest_retry_spawn_failed'
	end
	obs_log(state.svc, 'debug', {
		what = 'speedtest_retry_scheduled',
		uplink_id = uplink_id,
		generation = generation,
		retry_id = retry_id,
		delay_s = delay_s,
		reason = reason,
	})
	return true, nil
end

local function handle_speedtest_retry_due(state, ev)
	local pending = state.speedtest_retries and state.speedtest_retries[ev.uplink_id] or nil
	if type(pending) ~= 'table' or pending.retry_id ~= ev.retry_id then return true, nil end
	state.speedtest_retries[ev.uplink_id] = nil
	obs_log(state.svc, 'debug', {
		what = 'speedtest_retry_due',
		uplink_id = ev.uplink_id,
		generation = ev.generation,
		retry_id = ev.retry_id,
		reason = ev.reason,
	})
	return reconcile_speedtests_if_ready(state, 'speedtest_retry_due')
end

local function handle_speedtest_done(state, ev)
	local ok, err = wan_manager.handle_speedtest_done(state, ev)
	if ok == true and err ~= 'stale' then
		local snap = state.model:snapshot()
		local rec = snap.wan_runtime and snap.wan_runtime.speedtests and snap.wan_runtime.speedtests[ev.uplink_id]
		if rec then
			local mbps = rec.ok == true and tonumber(rec.peak_mbps) or nil
			obs_log(state.svc, rec.ok == true and 'info' or 'warn', {
				what = 'speedtest_completed',
				summary = rec.ok == true
					and string.format('speedtest %s on %s/%s: %.1f Mbps', tostring(ev.uplink_id), tostring(rec.interface or '?'), tostring(rec.device or '?'), mbps or 0)
					or string.format('speedtest %s failed: %s', tostring(ev.uplink_id), tostring(rec.err or 'unknown')),
				uplink_id = ev.uplink_id,
				interface = rec.interface,
				device = rec.device,
				ok = rec.ok == true,
				err = rec.err,
				peak_mbps = mbps,
				retry_delay_s = rec.retry_delay_s,
				retry_after = rec.retry_after,
				failure_count = rec.failure_count,
			})
		end
		if rec and rec.ok == true and rec.peak_mbps ~= nil and state.svc and type(state.svc.obs_metric) == 'function' then
			state.svc:obs_metric('speedtest', {
				value = rec.peak_mbps,
				namespace = { 'net', rec.interface or ev.uplink_id, 'speedtest' },
			})
		end
		if rec and rec.ok ~= true and rec.retry_after then
			local delay_s = math.max(1, (tonumber(rec.retry_after) or (now() + (tonumber(rec.retry_delay_s) or 10))) - now())
			local rok, rerr = schedule_speedtest_retry(state, tostring(ev.uplink_id or ''), ev.generation, delay_s, rec.err or 'speedtest_failed')
			if rok ~= true then return nil, rerr end
		end
	end
	mark_domain_dirty(state, 'wan_runtime')
	local pub_ok, pub_err = publish_snapshot(state)
	if pub_ok ~= true then return nil, pub_err end
	if ok == true and err == 'stale' then return true, nil end
	return ok, err
end

local function handle_live_weights_done(state, ev)
	local ok, err = wan_manager.handle_live_weights_done(state, ev)
	local result = ev and ev.result and (ev.result.result or ev.result) or {}
	if ok == true and err ~= 'stale' then
		if result.ok == true then
			state._live_weight_failure_log = nil
			local detail = type(result.detail) == 'table' and result.detail or {}
			local effective = type(detail.members) == 'table' and detail.members or {}
			local skipped = type(detail.skipped_members) == 'table' and detail.skipped_members or {}
			local effective_names, skipped_names = {}, {}
			for i = 1, #effective do
				effective_names[#effective_names + 1] = tostring(effective[i].semantic_interface or effective[i].interface or effective[i].id or '?')
			end
			for i = 1, #skipped do
				skipped_names[#skipped_names + 1] = tostring(skipped[i].semantic_interface or skipped[i].interface or skipped[i].id or '?')
			end
			local suffix = ''
			if #skipped_names > 0 then
				suffix = ' effective=' .. (#effective_names > 0 and table.concat(effective_names, ',') or '?')
					.. ' skipped=' .. table.concat(skipped_names, ',') .. ' reason=no_mwan3_mark'
			end
			obs_log(state.svc, 'info', {
				what = 'live_weights_applied',
				summary = string.format('live weights applied generation=%s%s', tostring(ev.generation or '?'), suffix),
				generation = ev.generation,
				weight_apply_id = ev.weight_apply_id,
				skipped_members = skipped,
				effective_members = effective,
			})
		else
			local signature = tostring(ev.generation or '?') .. ':' .. tostring(result.err or 'unknown')
			local rec = state._live_weight_failure_log
			local tnow = now()
			if not rec or rec.signature ~= signature then
				rec = { signature = signature, repeats = 0, first_at = tnow, last_logged_at = tnow }
				state._live_weight_failure_log = rec
				obs_log(state.svc, 'warn', {
					what = 'live_weights_failed',
					summary = string.format('live weights failed generation=%s: %s', tostring(ev.generation or '?'), tostring(result.err or 'unknown')),
					generation = ev.generation,
					weight_apply_id = ev.weight_apply_id,
					err = result.err,
				})
			else
				rec.repeats = (rec.repeats or 0) + 1
				if tnow - (rec.last_logged_at or rec.first_at or tnow) >= 60 then
					rec.last_logged_at = tnow
					obs_log(state.svc, 'warn', {
						what = 'live_weights_still_failing',
						summary = string.format('live weights still failing generation=%s (%d repeat%s): %s', tostring(ev.generation or '?'), rec.repeats, rec.repeats == 1 and '' or 's', tostring(result.err or 'unknown')),
						generation = ev.generation,
						weight_apply_id = ev.weight_apply_id,
						repeats = rec.repeats,
						err = result.err,
					})
				end
			end
		end
	end
	mark_domain_dirty(state, 'wan_runtime')
	local pub_ok, pub_err = publish_snapshot(state)
	if pub_ok ~= true then return nil, pub_err end
	if ok == true and err ~= 'stale' then log_net_summary(state, 'live_weights_done') end
	if ok == true and err == 'stale' then return true, nil end
	return ok, err
end

local function handle_event(state, ev)
	if ev.kind == 'config_changed' then
		return handle_config_changed(state, ev)
	elseif ev.kind == 'net_apply_done' then
		return handle_apply_done(state, ev)
	elseif ev.kind == 'observed_state' then
		return handle_observed_state(state, ev)
	elseif ev.kind == 'gsm_uplink_changed' or ev.kind == 'gsm_uplink_replay_done' or ev.kind == 'gsm_uplink_unknown' then
		return handle_gsm_uplink_changed(state, ev)
	elseif ev.kind == 'gsm_uplink_watch_closed' then
		state.gsm_uplink_watch = nil
		return true, nil
	elseif ev.kind == 'net_speedtest_done' then
		return handle_speedtest_done(state, ev)
	elseif ev.kind == 'speedtest_retry_due' then
		return handle_speedtest_retry_due(state, ev)
	elseif ev.kind == 'net_live_weights_done' then
		return handle_live_weights_done(state, ev)
	elseif ev.kind == 'net_observation_started' then
		return handle_observation_started(state, ev)
	elseif ev.kind == 'capability_status' or ev.kind == 'capability_dependency_changed' then
		return handle_dependency_status(state, ev)
	elseif ev.kind == 'capability_dependency_closed' then
		return handle_dependency_status(state, ev)
	elseif ev.kind == 'capability_status_closed' then
		if state.capability_status_subs then state.capability_status_subs[ev.capability] = nil end
		return true, nil
	elseif ev.kind == 'observation_closed' then
		state.observed_sub = nil
		if state.observer then state.observer:terminate('observation_closed'); state.observer = nil end
		state.model:update(function (m) return project_dependencies(state, m) end)
		mark_summary_dirty(state)
		return publish_snapshot(state)
	elseif ev.kind == 'config_watch_closed' then
		return nil, ev.err or 'config_watch_closed'
	elseif ev.kind == 'completion_queue_closed' then
		return nil, 'completion_queue_closed'
	elseif ev.kind == 'config_event_unknown' then
		obs_log(state.svc, 'warn', { what = 'config_event_unknown', event = ev.event })
		return true, nil
	end
	obs_log(state.svc, 'debug', { what = 'ignored_event', kind = tostring(ev.kind) })
	return true, nil
end

function M.run(scope, params)
	if type(scope) ~= 'table' then error('net.service.run: scope required', 2) end
	params = params or {}
	if type(params) ~= 'table' then error('net.service.run: params table required', 2) end

	local conn = params.conn
	local svc = params.svc or (conn and service_base.new(conn, { name = params.name or 'net', env = params.env })) or nil
	local service_id = new_service_id(params.service_id or params.name or 'net')
	local model = model_mod.new(service_id, { label = 'net.service' })
	local done_tx, done_rx = mailbox.new(params.done_queue_len or backpressure.policy.completions.queue_len, { full = backpressure.policy.completions.full })
	local published = publisher.new_state()
	local dirty = publisher.mark_all(publisher.new_dirty_state())
	local cfg_watch
	local gsm_watch

	if conn then
		local werr
		cfg_watch, werr = config_watch.open(conn, 'net', {
			queue_len = params.config_queue_len or backpressure.policy.config.queue_len,
			full = backpressure.policy.config.full,
			changed_kind = 'config_changed',
			closed_kind = 'config_closed',
		})
		if not cfg_watch then error(werr or 'net config watch failed', 2) end

		if params.gsm_uplink_watch ~= false then
			local gerr
			gsm_watch, gerr = gsm_uplink_watch.open(conn, {
				queue_len = params.gsm_uplink_queue_len or ((backpressure.policy.gsm_uplinks and backpressure.policy.gsm_uplinks.queue_len) or 8),
				full = params.gsm_uplink_full or ((backpressure.policy.gsm_uplinks and backpressure.policy.gsm_uplinks.full) or 'reject_newest'),
			})
			if not gsm_watch then error(gerr or 'net gsm uplink watch failed', 2) end
		end
	end

	local cap_deps = assert(cap_deps_mod.open(conn, {
		{ key = 'network_config', class = 'network-config', ref = params.hal_client and params.hal_client.network_config_cap, required = true },
		{ key = 'network_state', class = 'network-state', ref = params.hal_client and params.hal_client.network_state_cap, required = false },
		{ key = 'network_diagnostics', class = 'network-diagnostics', ref = params.hal_client and params.hal_client.network_diagnostics_cap, required = false },
	}, params.hal_client or {}))

	local hal = params.hal or hal_client_mod.new(conn, {
		network_config_cap = cap_deps:ref('network_config'),
		network_state_cap = cap_deps:ref('network_state'),
		network_diagnostics_cap = cap_deps:ref('network_diagnostics'),
	})

	local state = {
		conn = conn,
		svc = svc,
		scope = scope,
		service_id = service_id,
		model = model,
		published = published,
		dirty = dirty,
		config_watch = cfg_watch,
		gsm_uplink_watch = gsm_watch,
		observed_sub = nil,
		observer = nil,
		observe = params.observe ~= false,
		observation_queue_len = params.observation_queue_len or ((backpressure.policy.observations and backpressure.policy.observations.queue_len) or 32),
		observation_full = params.observation_full or ((backpressure.policy.observations and backpressure.policy.observations.full) or 'drop_oldest'),
		observation_options = params.observation or {},
		done_tx = done_tx,
		done_rx = done_rx,
		pending = {},
		hal = hal,
		cap_deps = cap_deps,
		capability_status_subs = nil,
		next_generation = 1,
		next_apply_id = 1,
		next_speedtest_id = 1,
		next_speedtest_retry_id = 1,
		next_weight_apply_id = 1,
		active_speedtests = {},
		speedtest_retries = {},
		active_weight_apply = nil,
		counter_poll_enabled = params.counter_metrics ~= false and params.counter_poll ~= false,
		counter_poll_interval_s = params.counter_poll_interval_s or params.counter_metrics_interval_s or 60,
		counter_poll_timeout_s = params.counter_poll_timeout_s or 5,
		current_generation = nil,
		active_apply = nil,
		pending_intent = nil,
		pending_apply_reason = nil,
		now = now,
	}
	state.mark_dirty = function(kind, name)
		if kind == 'domain' then mark_domain_dirty(state, name)
		elseif kind == 'apply' then mark_apply_dirty(state)
		elseif kind == 'summary' then mark_summary_dirty(state)
		else mark_all_dirty(state) end
	end

	if state.counter_poll_enabled and conn then
		scope:spawn(function () metrics.counter_metrics_loop(state) end)
	end

	scope:finally(function (_, status, primary)
		local reason = primary or status or 'net service closed'
		cancel_active_generation(state, reason)
		stop_observer(state, reason)
		if cfg_watch then cfg_watch:close(); cfg_watch = nil end
		if gsm_watch then gsm_watch:close(); gsm_watch = nil end
		cap_deps:terminate(reason)
		done_tx:close(reason)
		publisher.cleanup_now(conn, published)
		model:terminate(reason)
	end)

	if svc then
		svc:spawn_heartbeat(params.heartbeat_s or 30.0, 'tick')
		set_status(svc, 'starting')
		obs_log(svc, 'debug', { what = 'service_start' })
	end

	set_model_state(state, 'waiting_for_config', 'no_config')
	reconcile_observer_admission(state, 'service_start')
	publish_snapshot(state)

	if params.config ~= nil then
		local ok, err = handle_config_changed(state, { kind = 'config_changed', payload = params.config, rev = params.rev })
		if ok ~= true then error(err or 'initial net config failed', 2) end
	end

	while true do
		local ev = perform(events.next_service_event_op(state))
		local ok, err = handle_event(state, ev)
		if ok ~= true then
			set_status(svc, 'failed', { reason = tostring(err) })
			error(err or 'net service event failed', 0)
		end
	end
end

function M.start(conn, opts)
	opts = opts or {}
	opts.conn = conn
	return M.run(fibers.current_scope(), opts)
end

return M
