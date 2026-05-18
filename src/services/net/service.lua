-- services/net/service.lua
-- NET service coordinator.
--
-- NET owns product-level network intent and publication.  HAL owns host/network
-- mechanics.  The coordinator has one suspending control point; blocking work is
-- admitted through scoped components.

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
local stale = require 'services.net.stale'
local hal_client_mod = require 'services.net.hal_client'
local cap_resolver_mod = require 'services.net.capability_resolver'
local observer_manager = require 'services.net.observer_manager'
local wan_manager = require 'services.net.wan_manager'
local drift = require 'services.net.drift'
local backpressure = require 'services.net.backpressure'

local perform = fibers.perform

local M = {}

local function now() return fibers.now() end

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

local function mark_apply_dirty(state)
	publisher.mark_apply(state.dirty)
end

local function mark_summary_dirty(state)
	publisher.mark_summary(state.dirty)
end

local function publish_snapshot(state)
	if not state.conn then
		publisher.clear_dirty(state.dirty)
		return true, nil
	end
	return publisher.publish_dirty_now(state.conn, state.model:snapshot(), state.dirty, state.published)
end

local function set_model_state(state, service_state, reason)
	state.model:update(function (s)
		s.state = service_state
		s.ready = service_state == 'running'
		s.reason = reason
		return s
	end)
	mark_summary_dirty(state)
	return publish_snapshot(state)
end

local function hal_status_value(state, key)
	if state.cap_resolver and state.cap_resolver.status then
		return state.cap_resolver.status[key] or 'configured'
	end
	if key == 'network_config' and state.hal and type(state.hal.available) == 'function' then
		return state.hal:available() and 'available' or 'not_configured'
	end
	if key == 'network_state' and state.hal and type(state.hal.observation_available) == 'function' then
		return state.hal:observation_available() and 'available' or 'not_configured'
	end
	if key == 'network_diagnostics' and state.hal and type(state.hal.speedtest_op) == 'function' then
		return 'configured'
	end
	return 'not_configured'
end

local function update_hal_statuses(state)
	state.model:update(function (s)
		s.hal = s.hal or {}
		s.hal.network_config = hal_status_value(state, 'network_config')
		s.hal.network_state = hal_status_value(state, 'network_state')
		s.hal.network_diagnostics = hal_status_value(state, 'network_diagnostics')
		return s
	end)
	mark_summary_dirty(state)
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
	return true, nil
end

local function start_apply_for_intent(state, intent, reason)
	local generation = intent.generation
	local apply_id = state.next_apply_id
	state.next_apply_id = apply_id + 1

	local gen = generation_mod.new(generation, intent, reason, { now = now() })
	generation_mod.start_apply(gen, apply_id, { now = now() })
	state.current_generation = gen
	state.active_apply = { generation = generation, apply_id = apply_id, rev = intent.rev }

	state.model:update(function (s)
		s.state = 'applying'
		s.ready = false
		s.reason = nil
		s.generation = generation
		s.config = { rev = intent.rev, schema = intent.schema, config_schema = intent.config_schema, version = intent.version }
		s.intent = s.intent or {}
		s.intent.active = generation_mod.snapshot(gen)
		s.intent.generation = generation
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
		s.wan_runtime = { generation = generation, uplinks = {}, speedtests = {}, live_weights = { state = 'idle', generation = generation } }
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
		s.hal.network_config = hal_status_value(state, 'network_config')
		s.stats.config_updates = (s.stats.config_updates or 0) + 1
		s.stats.apply_started = (s.stats.apply_started or 0) + 1
		return s
	end)
	mark_all_dirty(state)
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
		generation_mod.mark_failed(gen, err or 'apply_start_failed', nil, { now = now() })
		state.active_apply = nil
		state.model:update(function (s)
			s.intent.active = generation_mod.snapshot(gen)
			s.apply.state = 'failed_to_start'
			s.apply.last_error = tostring(err or 'apply_start_failed')
			return s
		end)
		mark_apply_dirty(state)
		return nil, err
	end

	gen.apply_handle = handle
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
			s.intent = s.intent or {}
			s.intent.last_rejected = { rev = ev.rev, err = tostring(err), rejected_at = now() }
			return s
		end)
		mark_summary_dirty(state)
		return publish_snapshot(state)
	end

	state.next_generation = intent.generation + 1
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
			return s
		end)
		mark_summary_dirty(state)
		publish_snapshot(state)
		return nil, apply_err or 'net apply start failed'
	end
	return true, nil
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
		s.apply.state = apply_ok and 'applied' or 'failed'
		s.apply.completed_at = now()
		s.apply.last_result = result.result
		s.apply.last_error = reason
		if apply_ok then s.apply.last_applied_rev = result.intent_rev or (s.config and s.config.rev) end
		s.stats.apply_completed = (s.stats.apply_completed or 0) + 1
		return s
	end)

	mark_apply_dirty(state)
	set_status(state.svc, apply_ok and 'running' or 'degraded', reason and { reason = reason } or nil)
	obs_event(state.svc, 'apply_completed', { generation = ev.generation, apply_id = ev.apply_id, ok = apply_ok, reason = reason })

	local ok_pub, pub_err = publish_snapshot(state)
	if ok_pub ~= true then return nil, pub_err end
	if apply_ok then
		local ok, err = wan_manager.start_speedtests(state)
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

	s.hal = s.hal or {}
	s.hal.network_state = 'available'
	s.stats.observations = (s.stats.observations or 0) + 1
	s.drift = drift.calculate(s, { now = now })
	return s
end

local function handle_observed_state(state, ev)
	local observed_event = ev and ev.event or nil
	if type(observed_event) ~= 'table' then return true, nil end
	state.model:update(function (s) return merge_observation(state, s, observed_event) end)
	mark_domain_dirty(state, 'observed')
	mark_domain_dirty(state, 'drift')
	obs_event(state.svc, 'network_observed', { subject = observed_event.subject, source = observed_event.source, kind = observed_event.kind })
	return publish_snapshot(state)
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
			m.hal.network_state = 'unavailable'
			m.observed.last_error = tostring(err)
			return m
		end)
		mark_summary_dirty(state)
		mark_domain_dirty(state, 'observed')
		return true, nil
	end
	state.observer = observer
	state.observed_sub = observer:subscription()
	state.model:update(function (m)
		m.hal.network_state = 'starting'
		return m
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

local function handle_observation_started(state, ev)
	local work = ev.result or {}
	local result = work.result or work
	local ok = ev.status == 'ok' and work.ok == true and (result.ok == nil or result.ok == true)
	state.model:update(function (m)
		m.hal.network_state = ok and 'available' or 'unavailable'
		if not ok then m.observed.last_error = result.err or ev.primary or 'observation_start_failed' end
		return m
	end)
	if not ok then stop_observer(state, 'observation_start_failed') end
	mark_summary_dirty(state)
	mark_domain_dirty(state, 'observed')
	return publish_snapshot(state)
end

local function handle_capability_status(state, ev)
	if not state.cap_resolver then return true, nil end
	local status = state.cap_resolver:record_status(ev.capability, ev.payload)
	state.model:update(function (m)
		m.hal = m.hal or {}
		m.hal[ev.capability] = status
		m.hal.last_status[ev.capability] = { status = status, payload = model_mod.deep_copy(ev.payload), updated_at = now() }
		return m
	end)
	mark_summary_dirty(state)
	if ev.capability == 'network_state' then
		if status == 'available' or status == 'running' then ensure_observer_started(state, 'capability_available')
		else stop_observer(state, 'network_state_' .. tostring(status)) end
	end
	return publish_snapshot(state)
end

local function handle_speedtest_done(state, ev)
	local ok, err = wan_manager.handle_speedtest_done(state, ev)
	mark_domain_dirty(state, 'wan_runtime')
	local pub_ok, pub_err = publish_snapshot(state)
	if pub_ok ~= true then return nil, pub_err end
	if ok == true and err == 'stale' then return true, nil end
	return ok, err
end

local function handle_live_weights_done(state, ev)
	local ok, err = wan_manager.handle_live_weights_done(state, ev)
	mark_domain_dirty(state, 'wan_runtime')
	local pub_ok, pub_err = publish_snapshot(state)
	if pub_ok ~= true then return nil, pub_err end
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
	elseif ev.kind == 'net_speedtest_done' then
		return handle_speedtest_done(state, ev)
	elseif ev.kind == 'net_live_weights_done' then
		return handle_live_weights_done(state, ev)
	elseif ev.kind == 'net_observation_started' then
		return handle_observation_started(state, ev)
	elseif ev.kind == 'capability_status' then
		return handle_capability_status(state, ev)
	elseif ev.kind == 'capability_status_closed' then
		if state.capability_status_subs then state.capability_status_subs[ev.capability] = nil end
		return true, nil
	elseif ev.kind == 'observation_closed' then
		state.observed_sub = nil
		if state.observer then state.observer:terminate('observation_closed'); state.observer = nil end
		state.model:update(function (m) m.hal.network_state = 'closed'; return m end)
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

	local cap_resolver
	local hal = params.hal
	if not hal then
		cap_resolver = assert(cap_resolver_mod.open(conn, params.hal_client or {}))
		hal = hal_client_mod.new(conn, cap_resolver:client_opts(params.hal_client or {}))
	end

	local state = {
		conn = conn,
		svc = svc,
		scope = scope,
		service_id = service_id,
		model = model,
		published = published,
		dirty = dirty,
		config_watch = cfg_watch,
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
		cap_resolver = cap_resolver,
		capability_status_subs = cap_resolver and cap_resolver.status_subs or nil,
		next_generation = 1,
		next_apply_id = 1,
		next_speedtest_id = 1,
		next_weight_apply_id = 1,
		active_speedtests = {},
		active_weight_apply = nil,
		current_generation = nil,
		active_apply = nil,
		now = now,
	}
	state.mark_dirty = function(kind, name)
		if kind == 'domain' then mark_domain_dirty(state, name)
		elseif kind == 'apply' then mark_apply_dirty(state)
		elseif kind == 'summary' then mark_summary_dirty(state)
		else mark_all_dirty(state) end
	end

	scope:finally(function (_, status, primary)
		local reason = primary or status or 'net service closed'
		cancel_active_generation(state, reason)
		stop_observer(state, reason)
		if cfg_watch then cfg_watch:close(); cfg_watch = nil end
		if cap_resolver then cap_resolver:close(); cap_resolver = nil end
		done_tx:close(reason)
		publisher.cleanup_now(conn, published)
		model:terminate(reason)
	end)

	if svc then
		svc:spawn_heartbeat(params.heartbeat_s or 30.0, 'tick')
		set_status(svc, 'starting')
		obs_log(svc, 'info', { what = 'service_start' })
	end

	update_hal_statuses(state)
	set_model_state(state, 'waiting_for_config', 'no_config')
	if state.observe ~= false then ensure_observer_started(state, 'service_start') end
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
