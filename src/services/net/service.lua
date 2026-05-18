-- services/net/service.lua
-- NET service coordinator skeleton.
--
-- The coordinator owns product-level network intent and publication.  All host
-- mutation is admitted as scoped work and goes through semantic HAL client
-- operations.  platform implementation details are deliberately
-- absent from this service layer.

local fibers = require 'fibers'
local mailbox = require 'fibers.mailbox'

local service_base = require 'devicecode.service_base'
local config_watch = require 'devicecode.support.config_watch'

local model_mod = require 'services.net.model'
local config_mod = require 'services.net.config'
local events = require 'services.net.events'
local publisher = require 'services.net.publisher'
local generation_mod = require 'services.net.generation'
local apply_runtime = require 'services.net.apply_runtime'
local wan_runtime = require 'services.net.wan_runtime'
local stale = require 'services.net.stale'
local hal_client_mod = require 'services.net.hal_client'
local backpressure = require 'services.net.backpressure'

local perform = fibers.perform

local M = {}

local function now()
	return fibers.now()
end

local function new_service_id(name)
	return tostring(name or 'net')
end

local function obs_log(svc, level, payload)
	if svc and type(svc.obs_log) == 'function' then
		svc:obs_log(level, payload)
	end
end

local function obs_event(svc, kind, payload)
	if svc and type(svc.obs_event) == 'function' then
		payload = payload or {}
		payload.kind = payload.kind or kind
		svc:obs_event(kind, payload)
	end
end

local function set_status(svc, state, fields)
	if svc and type(svc.status) == 'function' then
		svc:status(state, fields)
	end
end

local function publish_snapshot(state)
	if not state.conn then return true, nil end
	return publisher.publish_all_now(state.conn, state.model:snapshot(), state.published)
end

local function set_model_state(state, service_state, reason)
	state.model:update(function (s)
		s.state = service_state
		s.ready = service_state == 'running'
		s.reason = reason
		return s
	end)
	return publish_snapshot(state)
end

local function normalise_config_event(state, ev)
	local generation = state.next_generation
	local intent, err = config_mod.normalise(ev.payload, {
		rev = ev.rev,
		generation = generation,
	})
	if not intent then return nil, err end
	return intent, nil
end

local function cancel_active_runtime(state, reason)
	for _, rec in pairs(state.active_speedtests or {}) do
		if rec.handle and type(rec.handle.cancel) == 'function' then rec.handle:cancel(reason or 'runtime_replaced') end
	end
	state.active_speedtests = {}
	if state.active_weight_apply and state.active_weight_apply.handle and type(state.active_weight_apply.handle.cancel) == 'function' then
		state.active_weight_apply.handle:cancel(reason or 'runtime_replaced')
	end
	state.active_weight_apply = nil
	return true, nil
end

local function cancel_active_generation(state, reason)
	cancel_active_runtime(state, reason or 'generation_replaced')
	local active = state.current_generation
	if not active then return true, nil end
	active.state = 'replacing'
	generation_mod.cancel(active, reason or 'generation_replaced')
	state.current_generation = nil
	return true, nil
end

local function start_apply_for_intent(state, intent, reason)
	local generation = intent.generation
	local apply_id = state.next_apply_id
	state.next_apply_id = apply_id + 1

	local gen = generation_mod.new(generation, intent, reason)
	state.current_generation = gen
	state.active_apply = {
		generation = generation,
		apply_id = apply_id,
		rev = intent.rev,
	}

	state.model:update(function (s)
		s.state = 'applying'
		s.ready = false
		s.reason = nil
		s.generation = generation
		s.config = {
			rev = intent.rev,
			schema = intent.schema,
			config_schema = intent.config_schema,
			version = intent.version,
		}
		s.segments = intent.segments or {}
		s.vlan_policy = intent.vlan_policy or {}
		s.policies = intent.policies or {}
		s.interfaces = intent.interfaces or {}
		s.addressing = intent.addressing or {}
		s.dns = intent.dns or {}
		s.dhcp = intent.dhcp or {}
		s.firewall = intent.firewall or {}
		s.routing = intent.routing or {}
		s.wan = intent.wan or {}
		s.shaping = intent.shaping or {}
		s.vpn = intent.vpn or {}
		s.diagnostics = intent.diagnostics or {}
		s.apply = {
			state = 'running',
			generation = generation,
			apply_id = apply_id,
			started_at = now(),
			last_applied_rev = s.apply and s.apply.last_applied_rev or nil,
			last_error = nil,
			last_result = nil,
		}
		s.hal.network_config = state.hal:available() and 'available' or 'not_configured'
		s.stats.config_updates = (s.stats.config_updates or 0) + 1
		s.stats.apply_started = (s.stats.apply_started or 0) + 1
		return s
	end)

	local ok_pub, pub_err = publish_snapshot(state)
	if ok_pub ~= true then return nil, pub_err end

	local handle, err = apply_runtime.start_apply {
		lifetime_scope = state.scope,
		reaper_scope = state.scope,
		report_scope = state.scope,
		service_id = state.service_id,
		generation = generation,
		apply_id = apply_id,
		intent = intent,
		hal = state.hal,
		done_tx = state.done_tx,
	}
	if not handle then
		state.active_apply = nil
		state.current_generation = nil
		return nil, err
	end

	gen.apply_handle = handle
	state.next_generation = generation + 1
	return true, nil
end

local function handle_config_changed(state, ev)
	local intent, err = normalise_config_event(state, ev)
	if not intent then
		obs_log(state.svc, 'warn', { what = 'config_rejected', err = tostring(err) })
		state.model:update(function (s)
			s.state = 'degraded'
			s.ready = false
			s.reason = tostring(err)
			return s
		end)
		publish_snapshot(state)
		return true, nil
	end

	cancel_active_generation(state, 'config_replaced')
	obs_event(state.svc, 'config_accepted', {
		rev = intent.rev,
		generation = intent.generation,
		segments = intent.stats and intent.stats.segments or nil,
		interfaces = intent.stats and intent.stats.interfaces or nil,
	})

	local ok, apply_err = start_apply_for_intent(state, intent, 'config_changed')
	if ok ~= true then
		state.model:update(function (s)
			s.state = 'degraded'
			s.ready = false
			s.reason = tostring(apply_err or 'apply_start_failed')
			s.apply.state = 'failed_to_start'
			s.apply.last_error = tostring(apply_err or 'apply_start_failed')
			return s
		end)
		publish_snapshot(state)
		return nil, apply_err or 'net apply start failed'
	end
	return true, nil
end

local start_speedtests_for_wan

local function handle_apply_done(state, ev)
	if not stale.apply_current(state, ev) then
		stale.reject(state, ev)
		publish_snapshot(state)
		return true, nil
	end

	local result = ev.result or {}
	local apply_ok = ev.status == 'ok' and result.ok == true
	local reason = nil
	if not apply_ok then
		reason = ev.primary or (result.result and result.result.err) or 'apply_failed'
	end

	state.active_apply = nil
	if state.current_generation then
		state.current_generation.state = apply_ok and 'applied' or 'failed'
	end

	state.model:update(function (s)
		s.state = apply_ok and 'running' or 'degraded'
		s.ready = apply_ok
		s.reason = reason
		s.apply.state = apply_ok and 'applied' or 'failed'
		s.apply.completed_at = now()
		s.apply.last_result = result.result
		s.apply.last_error = reason
		if apply_ok then
			s.apply.last_applied_rev = result.intent_rev or (s.config and s.config.rev)
		end
		s.stats.apply_completed = (s.stats.apply_completed or 0) + 1
		return s
	end)

	set_status(state.svc, apply_ok and 'running' or 'degraded', reason and { reason = reason } or nil)
	obs_event(state.svc, 'apply_completed', {
		generation = ev.generation,
		apply_id = ev.apply_id,
		ok = apply_ok,
		reason = reason,
	})

	local ok_pub, pub_err = publish_snapshot(state)
	if ok_pub ~= true then return nil, pub_err end
	if apply_ok then return start_speedtests_for_wan(state) end
	return true, nil
end


local function compute_drift(snapshot)
	local items = {}
	local desired_ifaces = snapshot.interfaces or {}
	local observed = snapshot.observed or {}
	local observed_ifaces = observed.interfaces or {}

	for id, _ in pairs(desired_ifaces) do
		if observed_ifaces[id] == nil then
			items[#items + 1] = { kind = 'missing_interface', interface = id }
		end
	end
	for id, obs in pairs(observed_ifaces) do
		local desired = desired_ifaces[id]
		if desired == nil then
			items[#items + 1] = { kind = 'unexpected_interface', interface = id }
		elseif desired.enabled ~= false and obs.enabled == false then
			items[#items + 1] = { kind = 'interface_disabled', interface = id }
		end
	end

	return {
		converged = #items == 0,
		items = items,
		updated_at = now(),
	}
end

local function merge_observation(s, observed_event)
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

	s.hal = s.hal or {}
	s.hal.network_state = 'available'
	s.stats.observations = (s.stats.observations or 0) + 1
	s.drift = compute_drift(s)
	return s
end



local function speedtest_flag_enabled(v)
	if v == true then return true end
	if type(v) == 'table' then return v.enabled ~= false end
	return false
end

local function speedtest_enabled(snapshot)
	local wan = snapshot and snapshot.wan or {}
	local lb = type(wan.load_balancing) == 'table' and wan.load_balancing or {}
	local rt = type(wan.runtime) == 'table' and wan.runtime or {}
	return speedtest_flag_enabled(lb.speedtest)
		or speedtest_flag_enabled(lb.speedtests)
		or speedtest_flag_enabled(rt.speedtest)
		or speedtest_flag_enabled(rt.speedtests)
end

local function wan_member_interface(member, uplink_id)
	member = member or {}
	return member.openwrt_interface
		or member.network_interface
		or member.interface
		or member.iface
		or member.link_id
		or uplink_id
end

local function build_speedtest_request(snapshot, uplink_id, member)
	member = member or {}
	local iface_id = wan_member_interface(member, uplink_id)
	local iface = snapshot.interfaces and snapshot.interfaces[iface_id] or nil
	local endpoint = type(iface) == 'table' and type(iface.endpoint) == 'table' and iface.endpoint or {}
	return {
		interface = iface_id,
		device = member.device or member.linux_interface or member.ifname or endpoint.ifname or endpoint.device or endpoint.name or (iface and iface.device),
		url = member.speedtest_url,
		max_duration_s = member.speedtest_duration_s,
		uplink_id = uplink_id,
		metric = member.metric or member.priority or 1,
	}
end

local function collect_wan_uplinks(snapshot)
	local out = {}
	local members = snapshot and snapshot.wan and snapshot.wan.members or {}
	for _, uplink_id in ipairs((function(t)
		local ks = {}
		for k in pairs(t or {}) do ks[#ks + 1] = k end
		table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
		return ks
	end)(members)) do
		local member = members[uplink_id]
		if type(member) == 'table' and member.enabled ~= false and member.disabled ~= true then
			local req = build_speedtest_request(snapshot, uplink_id, member)
			if type(req.interface) == 'string' and req.interface ~= '' then
				out[#out + 1] = {
					uplink_id = tostring(uplink_id),
					member = model_mod.deep_copy(member),
					request = req,
				}
			end
		end
	end
	return out
end

local function start_speedtest_for_uplink(state, uplink)
	if not state.hal or type(state.hal.speedtest_op) ~= 'function' then return true, nil end
	local snap = state.model:snapshot()
	if not speedtest_enabled(snap) then return true, nil end
	local generation = state.current_generation and state.current_generation.generation or snap.generation
	if type(generation) ~= 'number' or generation <= 0 then return true, nil end
	local uplink_id = uplink.uplink_id
	local prev = snap.wan_runtime and snap.wan_runtime.speedtests and snap.wan_runtime.speedtests[uplink_id]
	if prev and prev.state == 'running' and prev.generation == generation then return true, nil end

	local id = state.next_speedtest_id
	state.next_speedtest_id = id + 1
	state.model:update(function(s)
		s.wan_runtime = s.wan_runtime or { uplinks = {}, speedtests = {}, live_weights = {} }
		s.wan_runtime.uplinks[uplink_id] = {
			uplink_id = uplink_id,
			interface = uplink.request.interface,
			device = uplink.request.device,
			metric = uplink.request.metric,
			updated_at = now(),
		}
		s.wan_runtime.speedtests[uplink_id] = {
			state = 'running',
			generation = generation,
			id = id,
			uplink_id = uplink_id,
			interface = uplink.request.interface,
			device = uplink.request.device,
			metric = uplink.request.metric,
			started_at = now(),
		}
		s.stats.speedtests_started = (s.stats.speedtests_started or 0) + 1
		return s
	end)

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
			if rec then rec.state = 'failed_to_start'; rec.err = tostring(err) end
			return s
		end)
		return nil, err
	end
	state.active_speedtests[uplink_id] = { generation = generation, speedtest_id = id, handle = handle }
	return true, nil
end

function start_speedtests_for_wan(state)
	local snap = state.model:snapshot()
	if not speedtest_enabled(snap) then return true, nil end
	local uplinks = collect_wan_uplinks(snap)
	for i = 1, #uplinks do
		local ok, err = start_speedtest_for_uplink(state, uplinks[i])
		if ok ~= true then return nil, err end
	end
	publish_snapshot(state)
	return true, nil
end

local function all_generation_speedtests_done(snapshot, generation)
	local uplinks = collect_wan_uplinks(snapshot)
	if #uplinks == 0 then return false end
	local tests = snapshot.wan_runtime and snapshot.wan_runtime.speedtests or {}
	for i = 1, #uplinks do
		local id = uplinks[i].uplink_id
		local rec = tests[id]
		if not rec or rec.generation ~= generation or rec.state == 'running' then return false end
	end
	return true
end

local function compute_weights_from_speedtests(snapshot)
	local runtime = snapshot.wan_runtime or {}
	local tests = runtime.speedtests or {}
	local members, total = {}, 0
	for uplink_id, rec in pairs(tests) do
		if rec.state == 'done' and rec.ok == true then
			local mbps = tonumber(rec.peak_mbps) or 0
			if mbps > 0 then
				members[#members + 1] = { uplink_id = uplink_id, interface = rec.interface, metric = rec.metric or 1, mbps = mbps }
				total = total + mbps
			end
		end
	end
	if total <= 0 or #members == 0 then return nil end
	table.sort(members, function(a, b) return tostring(a.uplink_id) < tostring(b.uplink_id) end)
	local out = {}
	for i = 1, #members do
		local m = members[i]
		out[#out + 1] = {
			id = m.uplink_id,
			link_id = m.uplink_id,
			interface = m.interface,
			metric = math.max(1, math.floor(tonumber(m.metric or 1) or 1)),
			weight = math.max(1, math.floor((m.mbps / total) * 100 + 0.5)),
			measured_mbps = m.mbps,
		}
	end
	return out
end

local function start_live_weight_apply(state, members)
	if not members or #members == 0 or not state.hal or type(state.hal.apply_live_weights_op) ~= 'function' then return true, nil end
	local snap = state.model:snapshot()
	local generation = state.current_generation and state.current_generation.generation or snap.generation
	if type(generation) ~= 'number' or generation <= 0 then return true, nil end
	local id = state.next_weight_apply_id
	state.next_weight_apply_id = id + 1
	state.active_weight_apply = { generation = generation, weight_apply_id = id }
	state.model:update(function(s)
		s.wan_runtime = s.wan_runtime or { uplinks = {}, speedtests = {}, live_weights = {} }
		s.wan_runtime.live_weights = {
			state = 'running',
			generation = generation,
			id = id,
			members = model_mod.deep_copy(members),
			started_at = now(),
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
		policy = 'balanced',
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

local function handle_speedtest_done(state, ev)
	if not stale.speedtest_current(state, ev) then
		stale.reject(state, ev)
		return publish_snapshot(state)
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
		rec.peak_mbps = result.peak_mbps
		rec.data_mib = result.data_mib
		rec.duration_s = result.duration_s
		rec.completed_at = now()
		s.wan_runtime.speedtests[ev.uplink_id] = rec
		s.stats.speedtests_completed = (s.stats.speedtests_completed or 0) + 1
		return s
	end)
	local snap = state.model:snapshot()
	if not all_generation_speedtests_done(snap, ev.generation) then
		return publish_snapshot(state)
	end
	local weights = compute_weights_from_speedtests(snap)
	local ok, err = start_live_weight_apply(state, weights)
	publish_snapshot(state)
	return ok, err
end

local function handle_live_weights_done(state, ev)
	if not stale.live_weights_current(state, ev) then
		stale.reject(state, ev)
		return publish_snapshot(state)
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
			updated_at = now(),
		}
		s.stats.live_weight_applies = (s.stats.live_weight_applies or 0) + 1
		return s
	end)
	return publish_snapshot(state)
end

local function handle_observed_state(state, ev)
	local observed_event = ev and ev.event or nil
	if type(observed_event) ~= 'table' then return true, nil end
	state.model:update(function (s)
		return merge_observation(s, observed_event)
	end)
	obs_event(state.svc, 'network_observed', {
		subject = observed_event.subject,
		source = observed_event.source,
		kind = observed_event.kind,
	})
	return publish_snapshot(state)
end

local function handle_event(state, ev)
	if ev.kind == 'config_changed' then
		return handle_config_changed(state, ev)
	elseif ev.kind == 'net_apply_done' then
		return handle_apply_done(state, ev)
	elseif ev.kind == 'observed_state' then
		return handle_observed_state(state, ev)
	elseif ev.kind == 'net_speedtest_done' then
		return handle_speedtest_done(state, ev)
	elseif ev.kind == 'net_live_weights_done' then
		return handle_live_weights_done(state, ev)
	elseif ev.kind == 'observation_closed' then
		state.observed_sub = nil
		state.model:update(function (m) m.hal.network_state = 'closed'; return m end)
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
	local done_tx, done_rx = mailbox.new(params.done_queue_len or backpressure.policy.completions.queue_len, {
		full = backpressure.policy.completions.full,
	})
	local published = publisher.new_state()
	local cfg_watch
	local observed_sub

	if conn then
		local werr
		cfg_watch, werr = config_watch.open(conn, 'net', {
			queue_len = params.config_queue_len or backpressure.policy.config.queue_len,
			full = backpressure.policy.config.full,
			changed_kind = 'config_changed',
			closed_kind = 'config_closed',
		})
		if not cfg_watch then error(werr or 'net config watch failed', 2) end
	end

	local state = {
		conn = conn,
		svc = svc,
		scope = scope,
		service_id = service_id,
		model = model,
		published = published,
		config_watch = cfg_watch,
		observed_sub = observed_sub,
		done_tx = done_tx,
		done_rx = done_rx,
		pending = {},
		hal = params.hal or hal_client_mod.new(conn, params.hal_client or {}),
		next_generation = 1,
		next_apply_id = 1,
		next_speedtest_id = 1,
		next_weight_apply_id = 1,
		active_speedtests = {},
		active_weight_apply = nil,
		current_generation = nil,
		active_apply = nil,
	}


	if params.observe ~= false and state.hal and type(state.hal.open_observed_subscription) == 'function' then
		local sub, sub_err = state.hal:open_observed_subscription({
			queue_len = params.observation_queue_len or ((backpressure.policy.observations and backpressure.policy.observations.queue_len) or 32),
			full = params.observation_full or ((backpressure.policy.observations and backpressure.policy.observations.full) or 'drop_oldest'),
		})
		if sub then
			observed_sub = sub
			state.observed_sub = sub
			if type(state.hal.start_observation_op) == 'function' then
				local result = perform(state.hal:start_observation_op(params.observation or {}))
				state.model:update(function (m)
					m.hal.network_state = (result and result.ok == true) and 'available' or 'unavailable'
					if result and result.ok ~= true then
						m.observed.last_error = result.err
					end
					return m
				end)
			end
		else
			obs_log(svc, 'debug', { what = 'network_observation_not_started', err = tostring(sub_err) })
		end
	end



	scope:finally(function (_, status, primary)
		cancel_active_generation(state, primary or status or 'net service closed')
		if cfg_watch then cfg_watch:close(); cfg_watch = nil end
		if observed_sub and observed_sub.close then observed_sub:close(); observed_sub = nil end
		for _, rec in pairs(state.active_speedtests or {}) do if rec.handle and rec.handle.cancel then rec.handle:cancel(primary or status or 'net service closed') end end
		if state.active_weight_apply and state.active_weight_apply.handle and state.active_weight_apply.handle.cancel then state.active_weight_apply.handle:cancel(primary or status or 'net service closed') end
		done_tx:close(primary or status or 'net service closed')
		publisher.cleanup_now(conn, published)
		model:terminate(primary or status or 'net service closed')
	end)

	if svc then
		svc:spawn_heartbeat(params.heartbeat_s or 30.0, 'tick')
		set_status(svc, 'starting')
		obs_log(svc, 'info', { what = 'service_start' })
	end

	set_model_state(state, 'waiting_for_config', 'no_config')

	if params.config ~= nil then
		local ok, err = handle_config_changed(state, {
			kind = 'config_changed',
			payload = params.config,
			rev = params.rev,
		})
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
