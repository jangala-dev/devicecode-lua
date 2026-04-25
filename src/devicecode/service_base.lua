-- devicecode/service_base.lua
--
-- Small service scaffold:
--   * obs helpers (log/event/state)
--   * legacy svc/<name>/status retained publishing
--   * additive lifecycle helpers (announce/starting/running/set_ready/...)
--   * retained wait helper for other services
--
-- Compatibility:
--   * existing svc:status(...) semantics are preserved
--   * new lifecycle helpers publish richer payloads, including run_id/ready
--   * lifecycle retained topics are automatically unretained on scope exit
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

	function svc:announce_topic()
		return self:service_topic('announce')
	end

	function svc:obs_log(level, payload)
		self.conn:publish(t('obs', 'log', self.name, level), payload)
	end

	function svc:obs_event(name, payload)
		self.conn:publish(t('obs', 'event', self.name, name), payload)
	end

	function svc:obs_state(name, payload)
		self.conn:retain(t('obs', 'state', self.name, name), payload)
	end

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

	-- Consumer-side helper: wait on retained service status rather than probing.
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

	-- Scope-exit cleanup for lifecycle topics. This is additive and safe even if
	-- the service never used the richer helpers.
	if runtime.current_fiber() then
		local current_scope = fibers.current_scope and fibers.current_scope() or nil
		if current_scope and current_scope.finally then
			current_scope:finally(function()
				pcall(function() svc.conn:unretain(svc:status_topic()) end)
				if svc._announce_published then
					pcall(function() svc.conn:unretain(svc:announce_topic()) end)
				end
			end)
		end
	end

	return svc
end

return M
