-- devicecode/service_base.lua
--
-- Small service scaffold:
--   * obs helpers (legacy + v1)
--   * svc/<name>/status retained
--   * svc/<name>/meta retained
--   * svc/<name>/announce retained
--   * service run_id
--   * convenience lifecycle helpers
--   * best-effort retained-topic cleanup on scope exit
--
---@module 'devicecode.service_base'

local fibers  = require 'fibers'
local runtime = require 'fibers.runtime'
local sleep   = require 'fibers.sleep'
local op      = require 'fibers.op'

local tablex = require 'shared.table'

local ok_uuid, uuid = pcall(require, 'uuid')

local M = {}

local LOG_LEVELS = { trace = true, debug = true, info = true, warn = true, error = true, fatal = true }

local function normalise_log_level(level)
	level = tostring(level or 'info'):lower()
	if level == 'warning' then level = 'warn' end
	if LOG_LEVELS[level] then return level end
	return 'info'
end


local EXACT_MESSAGE_LEVEL = {
	['service start() entered'] = 'debug',
	['service running'] = 'debug',
	['service stopped'] = 'debug',
	['service stopping'] = 'debug',
	['bootstrap successful'] = 'debug',
	['bound cmd/config/set'] = 'debug',
	['waiting for filesystem capability'] = 'debug',
	['fetching mainflux config'] = 'debug',
	['mainflux config loaded'] = 'debug',
	['service is live'] = 'debug',
	['config received, applying'] = 'debug',
	['cloud config ready'] = 'debug',
	['NTP synced, waiting for config before scheduling publish'] = 'debug',
	['received initial retained sync state'] = 'debug',
	['installing alarm time source from realtime clock'] = 'debug',
	['alarm time source installed'] = 'debug',
}

local WHAT_LEVEL = {
	-- Common lifecycle and subscription plumbing.
	subscribed = 'debug',
	config_begin = 'debug',
	config_end = 'debug',
	config_applied = 'debug',
	service_start = 'debug',
	service_state_changed = 'debug',

	-- HAL manager/capability/driver plumbing.
	applied_config_created_driver = 'debug',
	manager_started = 'debug',
	device_registered = 'debug',
	capability_registered = 'debug',
	capability_unregistered = 'debug',
	device_unregistered = 'debug',
	wired_manager_started = 'debug',
	wired_manager_configured = 'debug',
	network_manager_started = 'debug',
	network_driver_configured = 'debug',
	band_driver_started = 'debug',
	radio_driver_started = 'debug',
	apply_config_received = 'debug',
	all_devices_registered = 'debug',
	hotplug_socket_listening = 'debug',
	cap_emit_missing_capability = 'debug',
	network_config_control_instrumented_build = 'debug',
	openwrt_network_provider_instrumented_build = 'debug',

	-- HAL request/transaction details.  The service-level transition should
	-- narrate the operator flow; these remain available for diagnosis.
	network_config_request_begin = 'debug',
	network_config_reply_done = 'debug',
	network_config_method_done = 'debug',
	network_config_request_detached = 'debug',
	network_config_request_cancelled = 'debug',
	network_config_reply_cancelled = 'debug',
	network_state_request_begin = 'debug',
	network_state_method_done = 'debug',
	network_state_reply_done = 'debug',
	network_diagnostics_request_begin = 'debug',
	network_diagnostics_method_done = 'debug',
	network_diagnostics_reply_done = 'debug',
	network_diagnostics_request_cancelled = 'debug',
	openwrt_apply_begin = 'debug',
	openwrt_apply_uci_transaction_begin = 'debug',
	openwrt_apply_uci_transaction_done = 'debug',
	openwrt_apply_shaping_wait_targets_begin = 'debug',
	openwrt_apply_shaping_wait_targets_done = 'debug',
	openwrt_apply_shaping_begin = 'debug',
	openwrt_apply_shaping_done = 'debug',
	openwrt_apply_done = 'debug',
	uci_transaction_begin = 'debug',
	uci_transaction_done = 'debug',
	uci_activation_phase_begin = 'debug',
	uci_activation_phase_done = 'debug',
	uci_activation_begin = 'debug',
	uci_activation_done = 'debug',

	-- Config/time/wifi dependency plumbing.
	creating_modem = 'debug',
	capability_selected = 'debug',
	capability_monitor_start = 'debug',
	waiting_for_time_capability = 'debug',
	band_cap_added = 'debug',
	band_cap_removed = 'debug',
	radio_cap_added = 'debug',
	radio_cap_removed = 'debug',
	fs_configs_cap_added = 'debug',
	fs_configs_cap_removed = 'debug',
	band_config_applied = 'debug',
	radio_config_applied = 'debug',

	-- Metrics successful path is high-frequency plumbing.
	metric_value = 'trace',
	http_publish_ok = 'trace',
}

local SERVICE_WHAT_LEVEL = {
	hal = {
		modem_detected = 'debug',
	},
	metrics = {
		config_received = 'debug',
		config_applied = 'debug',
		-- Time owns the operator story; metrics only needs this for scheduling.
		ntp_lost = 'debug',
	},
}

local function semantic_log_level(service, requested, payload)
	requested = normalise_log_level(requested)
	if type(payload) ~= 'table' then return requested end

	local what = payload.what and tostring(payload.what) or nil
	local msg = payload.message and tostring(payload.message) or nil
	local service_policy = SERVICE_WHAT_LEVEL[tostring(service or '')]
	local target = (service_policy and what and service_policy[what]) or (what and WHAT_LEVEL[what]) or (msg and EXACT_MESSAGE_LEVEL[msg])

	-- Pattern-based pruning for noisy success paths whose text includes data.
	if not target and msg then
		if msg:match('^publishing %d+ metric%(s%)$') then target = 'debug' end
		if msg:match('^config applied, next publish in ') then target = 'debug' end
	end

	-- Keep failed method completions visible even when the method name is generally debug,
	-- except for HAL/network operations where the owning domain service emits the
	-- operator narrative (for example net.live_weights_failed).
	if what and what:match('_method_done$') and payload.ok == false then
		if tostring(service or '') == 'hal' and what == 'network_config_method_done'
			and (payload.verb == 'apply_live_weights' or payload.verb == 'apply')
		then
			return 'debug'
		end
		return (requested == 'error' or requested == 'fatal') and requested or 'warn'
	end
	if payload.err ~= nil and target == 'debug' and (requested == 'warn' or requested == 'error' or requested == 'fatal') then
		-- Explicit warnings/errors with an error field stay visible unless they are
		-- known development/build markers in WHAT_LEVEL.
		if what == 'network_config_control_instrumented_build' or what == 'openwrt_network_provider_instrumented_build' or what == 'cap_emit_missing_capability' then
			return target
		end
		return requested
	end
	return target or requested
end

local function t(...) return { ... } end

local function wall()
	return os.date('%Y-%m-%d %H:%M:%S')
end

local function topic_to_string(topic)
	if type(topic) ~= 'table' then return tostring(topic) end
	local parts = {}
	for i = 1, #topic do parts[#parts + 1] = tostring(topic[i]) end
	return table.concat(parts, '/')
end

local function new_run_id()
	if ok_uuid and uuid and type(uuid.new) == 'function' then
		return tostring(uuid.new())
	end
	return ('run-%d-%d'):format(os.time(), math.random(1, 1000000))
end

local shallow_copy = tablex.shallow_copy

local function merge_payload(base, extra)
	local out = shallow_copy(base)
	if type(extra) == 'table' then
		for k, v in pairs(extra) do
			out[k] = v
		end
	end
	return out
end

local function sorted_keys(t)
	local keys = {}
	for k in pairs(t or {}) do keys[#keys + 1] = k end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	return keys
end

local function stable_status_value(v, key)
	if key == 'ts' or key == 'at' then return '' end
	if type(v) ~= 'table' then return tostring(v) end
	local out = { '{' }
	for _, k in ipairs(sorted_keys(v)) do
		if k ~= 'ts' and k ~= 'at' then
			out[#out + 1] = tostring(k)
			out[#out + 1] = '='
			out[#out + 1] = stable_status_value(v[k], k)
			out[#out + 1] = ';'
		end
	end
	out[#out + 1] = '}'
	return table.concat(out)
end

local function default_ready_predicate(payload, opts)
	if type(payload) ~= 'table' then return false end
	if payload.ready == true then return true end
	if opts and opts.accept_running_without_ready and payload.state == 'running' and payload.ready == nil then
		return true
	end
	return false
end

---@param conn any
---@param opts? { name?: string, env?: string, meta?: table, announce?: table }
---@return ServiceBase
function M.new(conn, opts)
	opts = opts or {}

	---@class ServiceBase
	local svc = {}

	svc.conn   = conn
	svc.name   = opts.name or 'service'
	svc.env    = opts.env or (os.getenv('DEVICECODE_ENV') or 'dev')
	svc.run_id = new_run_id()

	-- Track retained topics so we can clean them up on scope exit.
	svc._retained_topics = {}
	svc._announce_published = false
	svc._meta_published = false
	svc._lifecycle_state = nil
	svc._lifecycle_extra = nil
	svc._status_semantic_key = nil

	function svc:now() return runtime.now() end
	function svc:wall() return wall() end
	function svc:t(...) return t(...) end
	function svc:topic_to_string(topic) return topic_to_string(topic) end

	----------------------------------------------------------------------
	-- Service topics
	----------------------------------------------------------------------

	function svc:service_topic(kind)
		return t('svc', self.name, kind)
	end

	function svc:status_topic()
		return self:service_topic('status')
	end

	function svc:meta_topic()
		return self:service_topic('meta')
	end

	function svc:announce_topic()
		return self:service_topic('announce')
	end

	----------------------------------------------------------------------
	-- Observability topics
	----------------------------------------------------------------------

	function svc:obs_log_legacy_topic(level)
		return t('obs', 'log', self.name, level)
	end

	function svc:obs_event_legacy_topic(name)
		return t('obs', 'event', self.name, name)
	end

	function svc:obs_state_legacy_topic(name)
		return t('obs', 'state', self.name, name)
	end

	function svc:obs_event_topic(name)
		return t('obs', 'v1', self.name, 'event', name)
	end

	function svc:obs_metric_topic(name)
		return t('obs', 'v1', self.name, 'metric', name)
	end

	function svc:obs_counter_topic(name)
		return t('obs', 'v1', self.name, 'counter', name)
	end

	----------------------------------------------------------------------
	-- Internal retained helpers
	----------------------------------------------------------------------

	function svc:_track_retained(topic)
		self._retained_topics[topic_to_string(topic)] = topic
	end

	function svc:_retain(topic, payload)
		self.conn:retain(topic, payload)
		self:_track_retained(topic)
	end

	function svc:_publish_dual(legacy_topic, v1_topic, payload)
		self.conn:publish(legacy_topic, payload)
		self.conn:publish(v1_topic, payload)
	end

	function svc:_retain_dual(legacy_topic, v1_topic, payload)
		self.conn:retain(legacy_topic, payload)
		self.conn:retain(v1_topic, payload)
		self:_track_retained(legacy_topic)
		self:_track_retained(v1_topic)
	end

	function svc:base_payload(extra)
		return merge_payload({
			service = self.name,
			env     = self.env,
			run_id  = self.run_id,
			ts      = self:now(),
			at      = self:wall(),
		}, extra)
	end

	----------------------------------------------------------------------
	-- Observability helpers
	----------------------------------------------------------------------

	function svc:log(level, what, payload)
		level = normalise_log_level(level)

		if payload == nil and type(what) == 'table' then
			payload = what
			what = payload.what
		elseif payload == nil then
			payload = { message = tostring(what or ''), summary = tostring(what or '') }
			what = nil
		elseif type(payload) ~= 'table' then
			payload = { message = tostring(payload), summary = tostring(payload) }
		end

		local out = self:base_payload(payload)
		if what ~= nil and out.what == nil then out.what = tostring(what) end
		if out.summary == nil and type(out.message) == 'string' then out.summary = out.message end
		level = semantic_log_level(self.name, level, out)
		out.level = level

		self.conn:publish(self:obs_log_legacy_topic(level), out)
		self.conn:publish(self:obs_event_topic('log'), out)
		return out
	end

	function svc:obs_log(level, payload)
		return self:log(level, payload)
	end

	function svc:trace(what, payload) return self:log('trace', what, payload) end
	function svc:debug(what, payload) return self:log('debug', what, payload) end
	function svc:info(what, payload)  return self:log('info', what, payload) end
	function svc:warn(what, payload)  return self:log('warn', what, payload) end
	function svc:error(what, payload) return self:log('error', what, payload) end
	function svc:fatal(what, payload) return self:log('fatal', what, payload) end

	function svc:obs_event(name, payload)
		self:_publish_dual(
			self:obs_event_legacy_topic(name),
			self:obs_event_topic(name),
			payload
		)
	end

	function svc:obs_state(name, payload)
		-- Legacy retained state + v1 metric bridge for compatibility.
		self:_retain_dual(
			self:obs_state_legacy_topic(name),
			self:obs_metric_topic(name),
			payload
		)
	end

	function svc:obs_metric(name, payload)
		self:_retain(self:obs_metric_topic(name), payload)
	end

	function svc:obs_counter(name, payload)
		self.conn:publish(self:obs_counter_topic(name), payload)
	end


	local function retain_status_if_semantically_changed(self, payload)
		local key = stable_status_value(payload, nil)
		if self._status_semantic_key == key then return false end
		self._status_semantic_key = key
		self:_retain(self:status_topic(), payload)
		self:obs_state('status', payload)
		return true
	end

	----------------------------------------------------------------------
	-- Service identity / lifecycle
	----------------------------------------------------------------------

	function svc:meta(extra)
		local payload = self:base_payload(extra)
		self._meta_published = true
		self:_retain(self:meta_topic(), payload)
		return payload
	end

	function svc:announce(extra)
		local payload = self:base_payload(extra)
		self._announce_published = true
		self:_retain(self:announce_topic(), payload)
		return payload
	end

	function svc:status(state, extra)
		local payload = self:base_payload(merge_payload({ state = state }, extra))
		retain_status_if_semantically_changed(self, payload)
		return payload
	end

	function svc:lifecycle(state, extra)
		local payload = self:base_payload(merge_payload({ state = state }, extra))
		local prev_state = self._lifecycle_state
		local prev_ready = self._lifecycle_extra and self._lifecycle_extra.ready
		self._lifecycle_state = state
		self._lifecycle_extra = shallow_copy(extra)
		local changed = retain_status_if_semantically_changed(self, payload)
		if changed then
			local level = 'debug'
			if state == 'failed' then level = 'error'
			elseif state == 'degraded' then level = 'warn'
			elseif payload.ready == true and (prev_state ~= state or prev_ready ~= true) then level = 'info' end
			self:log(level, 'service_state_changed', {
				state = state,
				ready = payload.ready,
				previous_state = prev_state,
				reason = payload.reason,
			})
		end
		return payload
	end

	function svc:starting(extra)
		return self:lifecycle('starting', merge_payload({ ready = false }, extra))
	end

	function svc:running(extra)
		return self:lifecycle('running', merge_payload({ ready = false }, extra))
	end

	function svc:set_ready(is_ready, extra)
		if is_ready then
			return self:lifecycle('running', merge_payload({ ready = true }, extra))
		end
		return self:lifecycle('running', merge_payload({ ready = false }, extra))
	end

	function svc:ready(extra)
		return self:set_ready(true, extra)
	end

	function svc:degraded(extra)
		return self:lifecycle('degraded', merge_payload({ ready = false }, extra))
	end

	function svc:failed(reason, extra)
		return self:lifecycle('failed', merge_payload({ reason = reason, ready = false }, extra))
	end

	function svc:stopped(extra)
		return self:lifecycle('stopped', merge_payload({ ready = false }, extra))
	end

	----------------------------------------------------------------------
	-- Convenience helpers
	----------------------------------------------------------------------

	function svc:spawn_heartbeat(period_s, event_name)
		period_s = period_s or 30.0
		event_name = event_name or 'tick'

		fibers.spawn(function ()
			local n = 0
			while true do
				n = n + 1
				self:obs_event(event_name, { n = n, ts = self:now() })
				sleep.sleep(period_s)
			end
		end)
	end

	-- Initial retained identity/public presence.
	svc:meta(opts.meta)
	svc:announce(opts.announce)

	local scope = fibers.current_scope and fibers.current_scope() or nil
	if scope and scope.finally then
		scope:finally(function ()
			for _, topic in pairs(svc._retained_topics) do
				svc.conn:unretain(topic)
			end
		end)
	end

	return svc
end

--- Wait until a service reports ready/running/degraded via svc/<name>/status.
--- This is a compatibility helper for code that wants a simple blocking wait.
---
---@param conn any
---@param service_name string
---@param opts? { timeout?: number, accept_running_without_ready?: boolean, ready_predicate?: fun(payload:any, opts:table|nil):boolean }
---@return table|nil payload
---@return string|nil err
function M.wait_service_ready(conn, service_name, opts)
	opts = opts or {}

	local sub = conn:subscribe(t('svc', service_name, 'status'))
	local timeout = opts.timeout
	local ready_predicate = opts.ready_predicate or default_ready_predicate

	while true do
		local which, a, b

		if timeout then
			which, a, b = fibers.perform(op.named_choice{
				status  = sub:recv_op(),
				timeout = sleep.sleep_op(timeout),
			})
		else
			which, a, b = 'status', fibers.perform(sub:recv_op()), nil
		end

		if which == 'timeout' then
			sub:unsubscribe()
			return nil, 'timeout'
		end

		local msg, err = a, b
		if not msg then
			sub:unsubscribe()
			return nil, tostring(err or 'subscription closed')
		end

		if ready_predicate(msg.payload, opts) then
			sub:unsubscribe()
			return msg.payload, nil
		end
	end
end

M.default_ready_predicate = default_ready_predicate
M.normalise_log_level = normalise_log_level

return M
