-- devicecode/service_base.lua
--
-- Small service scaffold:
--   * obs helpers (legacy + obs/v1 compatibility)
--   * svc/<name>/status retained publishing
--   * additive lifecycle helpers (meta/announce, starting/running/set_ready/...)
--   * retained wait helper for other services
--
-- Compatibility policy:
--   * existing svc:status(...) semantics are preserved
--   * existing obs/log|event|state helpers are preserved
--   * announce() now publishes BOTH svc/<name>/meta (canonical) and
--     svc/<name>/announce (legacy-compatible)
--   * obs helpers fan out to BOTH obs/v1/... and legacy obs/... topics
--
---@module 'devicecode.service_base'

local fibers  = require 'fibers'
local runtime = require 'fibers.runtime'
local sleep   = require 'fibers.sleep'
local uuid    = require 'uuid'

local M = {}

local function t(...)
	return { ... }
end

local function wall()
	return os.date('%Y-%m-%d %H:%M:%S')
end

local function topic_to_string(topic)
	if type(topic) ~= 'table' then return tostring(topic) end
	local parts = {}
	for i = 1, #topic do
		parts[#parts + 1] = tostring(topic[i])
	end
	return table.concat(parts, '/')
end

local function copy_table(src)
	local out = {}
	if type(src) ~= 'table' then return out end
	for k, v in pairs(src) do out[k] = v end
	return out
end

local function merge_payload(base_payload, extra)
	local payload = copy_table(base_payload)
	if type(extra) == 'table' then
		for k, v in pairs(extra) do
			payload[k] = v
		end
	end
	return payload
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
---@param opts? { name?: string, env?: string }
---@return ServiceBase
function M.new(conn, opts)
	opts = opts or {}

	---@class ServiceBase
	local svc = {}

	svc.conn = conn
	svc.name = opts.name or 'service'
	svc.env  = opts.env or (os.getenv('DEVICECODE_ENV') or 'dev')

	-- New lifecycle state is tracked separately so old status() callers keep
	-- their current payload semantics.
	svc.run_id = tostring(uuid.new())
	svc._announce_published = false
	svc._meta_published = false
	svc._lifecycle_state = nil
	svc._lifecycle_extra = nil

	function svc:now()
		return runtime.now()
	end

	function svc:wall()
		return wall()
	end

	function svc:t(...)
		return t(...)
	end

	function svc:topic_to_string(topic)
		return topic_to_string(topic)
	end

	function svc:service_topic(kind)
		return t('svc', self.name, kind)
	end

	function svc:status_topic()
		return self:service_topic('status')
	end

	-- New canonical metadata surface.
	function svc:meta_topic()
		return self:service_topic('meta')
	end

	-- Legacy compatibility surface.
	function svc:announce_topic()
		return self:service_topic('announce')
	end

	----------------------------------------------------------------------
	-- Observability topics
	----------------------------------------------------------------------

	-- Legacy forms
	function svc:obs_log_legacy_topic(level)
		return t('obs', 'log', self.name, level)
	end

	function svc:obs_event_legacy_topic(name)
		return t('obs', 'event', self.name, name)
	end

	function svc:obs_state_legacy_topic(name)
		return t('obs', 'state', self.name, name)
	end

	-- New canonical obs/v1 forms
	function svc:obs_event_topic(name)
		return t('obs', 'v1', self.name, 'event', name)
	end

	function svc:obs_metric_topic(name)
		return t('obs', 'v1', self.name, 'metric', name)
	end

	function svc:obs_counter_topic(name)
		return t('obs', 'v1', self.name, 'counter', name)
	end

	-- Compatibility helper:
	--   * legacy log plane remains as-is
	--   * canonical plane treats logs as events named "log", with level attached
	function svc:obs_log(level, payload)
		self.conn:publish(self:obs_log_legacy_topic(level), payload)

		local v1_payload
		if type(payload) == 'table' then
			v1_payload = copy_table(payload)
			v1_payload.level = level
		else
			v1_payload = { level = level, message = payload }
		end
		self.conn:publish(self:obs_event_topic('log'), v1_payload)
	end

	-- Compatibility helper:
	--   * legacy event plane remains as-is
	--   * canonical plane is obs/v1/<service>/event/<name>
	function svc:obs_event(name, payload)
		self.conn:publish(self:obs_event_legacy_topic(name), payload)
		self.conn:publish(self:obs_event_topic(name), payload)
	end

	-- Compatibility helper:
	--   * legacy retained state plane remains as-is
	--   * canonical plane is exposed as a retained metric summary
	--
	-- Note: this is a bridge. Over time, individual callers should migrate to
	-- explicit obs_metric / obs_counter calls rather than using obs_state for
	-- everything.
	function svc:obs_state(name, payload)
		self.conn:retain(self:obs_state_legacy_topic(name), payload)
		self.conn:retain(self:obs_metric_topic(name), payload)
	end

	function svc:obs_metric(name, payload)
		self.conn:retain(self:obs_metric_topic(name), payload)
	end

	function svc:obs_counter(name, payload)
		self.conn:publish(self:obs_counter_topic(name), payload)
	end

	----------------------------------------------------------------------
	-- Lifecycle
	----------------------------------------------------------------------

	-- Compatibility path: keep the existing payload shape.
	function svc:status(state, extra)
		local payload = { state = state, ts = self:now(), at = self:wall() }
		if type(extra) == 'table' then
			for k, v in pairs(extra) do payload[k] = v end
		end
		self.conn:retain(self:status_topic(), payload)
		self:obs_state('status', payload)
		return payload
	end

	-- New lifecycle path: explicit ready/run_id semantics for dependants.
	function svc:lifecycle(state, extra)
		local payload = {
			state = state,
			ts = self:now(),
			at = self:wall(),
			run_id = self.run_id,
		}
		if type(extra) == 'table' then
			for k, v in pairs(extra) do payload[k] = v end
		end

		self._lifecycle_state = state
		self._lifecycle_extra = copy_table(extra)

		self.conn:retain(self:status_topic(), payload)
		self:obs_state('status', payload)
		return payload
	end

	-- Canonical service metadata + legacy announce alias.
	function svc:announce(meta)
		local payload = {
			name = self.name,
			env = self.env,
			run_id = self.run_id,
			ts = self:now(),
			at = self:wall(),
		}
		if type(meta) == 'table' then
			for k, v in pairs(meta) do payload[k] = v end
		end

		self._announce_published = true
		self._meta_published = true

		-- New canonical metadata topic
		self.conn:retain(self:meta_topic(), payload)
		-- Legacy compatibility topic
		self.conn:retain(self:announce_topic(), payload)

		return payload
	end

	function svc:starting(extra)
		local payload = merge_payload({ ready = false }, extra)
		return self:lifecycle('starting', payload)
	end

	-- Intentionally does not imply ready=true.
	function svc:running(extra)
		local payload = merge_payload({ ready = false }, extra)
		return self:lifecycle('running', payload)
	end

	function svc:degraded(extra)
		local ready = false
		if type(extra) == 'table' and extra.ready ~= nil then
			ready = not not extra.ready
		elseif type(self._lifecycle_extra) == 'table' and self._lifecycle_extra.ready ~= nil then
			ready = not not self._lifecycle_extra.ready
		end
		local payload = merge_payload({ ready = ready }, extra)
		return self:lifecycle('degraded', payload)
	end

	function svc:failed(reason, extra)
		local payload = merge_payload({ ready = false, reason = reason }, extra)
		return self:lifecycle('failed', payload)
	end

	function svc:set_ready(ready, extra)
		local state = self._lifecycle_state
		if ready and (state == nil or state == 'starting') then
			state = 'running'
		elseif state == nil then
			state = 'running'
		end
		local payload = merge_payload(self._lifecycle_extra or {}, extra)
		payload.ready = not not ready
		return self:lifecycle(state, payload)
	end

	function svc:spawn_heartbeat(period_s, event_name)
		period_s = period_s or 30.0
		event_name = event_name or 'tick'
		fibers.spawn(function()
			local n = 0
			while true do
				n = n + 1
				self:obs_event(event_name, { n = n, ts = self:now() })
				sleep.sleep(period_s)
			end
		end)
	end

	----------------------------------------------------------------------
	-- Consumer-side helper: wait on retained service status rather than probing.
	----------------------------------------------------------------------

	function svc:wait_service_ready(name, opts_)
		opts_ = opts_ or {}
		local timeout = (type(opts_.timeout) == 'number') and opts_.timeout or 30.0
		local queue_len = (type(opts_.queue_len) == 'number') and opts_.queue_len or 8
		local full = opts_.full or 'drop_oldest'
		local predicate = opts_.predicate or function(payload)
			return default_ready_predicate(payload, opts_)
		end

		local watch = self.conn:watch_retained(
			t('svc', name, 'status'),
			{ replay = true, queue_len = queue_len, full = full }
		)

		local deadline = self:now() + timeout

		local function cleanup()
			pcall(function() watch:unwatch() end)
		end

		while true do
			local remaining = deadline - self:now()
			if remaining <= 0 then
				cleanup()
				return nil, 'timeout'
			end

			local which, a, b = fibers.perform(fibers.named_choice({
				ev = watch:recv_op(),
				timeout = sleep.sleep_op(remaining):wrap(function()
					return true
				end),
			}))

			if which == 'timeout' then
				cleanup()
				return nil, 'timeout'
			end

			local ev, err = a, b
			if not ev then
				cleanup()
				return nil, err or 'watch_closed'
			end

			if ev.op == 'retain' and predicate(ev.payload) then
				local payload = ev.payload
				cleanup()
				return payload, nil
			end
		end
	end

	----------------------------------------------------------------------
	-- Scope-exit cleanup for lifecycle topics.
	----------------------------------------------------------------------

	if runtime.current_fiber() then
		local current_scope = fibers.current_scope and fibers.current_scope() or nil
		if current_scope and current_scope.finally then
			current_scope:finally(function()
				pcall(function() svc.conn:unretain(svc:status_topic()) end)

				if svc._meta_published then
					pcall(function() svc.conn:unretain(svc:meta_topic()) end)
				end

				if svc._announce_published then
					pcall(function() svc.conn:unretain(svc:announce_topic()) end)
				end
			end)
		end
	end

	return svc
end

return M
