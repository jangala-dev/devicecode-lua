-- devicecode/service_base.lua
--
-- Small service scaffold:
--   * obs helpers (log/event/state)
--   * svc/<name>/status retained
--   * HAL discovery (via retained svc/hal/announce)
--   * fixed HAL RPC calls (rpc/hal/<method>)
--
---@module 'devicecode.service_base'

local fibers  = require 'fibers'
local runtime = require 'fibers.runtime'
local sleep   = require 'fibers.sleep'

local perform      = fibers.perform
local named_choice = fibers.named_choice

local M = {}

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

---@param conn any
---@param opts? { name?: string, env?: string }
function M.new(conn, opts)
	opts = opts or {}
	local svc = {}

	svc.conn = conn
	svc.name = opts.name or 'service'
	svc.env  = opts.env or (os.getenv('DEVICECODE_ENV') or 'dev')

	function svc:now() return runtime.now() end
	function svc:wall() return wall() end
	function svc:t(...) return t(...) end
	function svc:topic_to_string(topic) return topic_to_string(topic) end

	function svc:obs_log(level, payload)
		self.conn:publish(t('obs', 'log', self.name, level), payload)
	end

	function svc:obs_event(name, payload)
		self.conn:publish(t('obs', 'event', self.name, name), payload)
	end

	function svc:obs_state(name, payload)
		self.conn:retain(t('obs', 'state', self.name, name), payload)
	end

	function svc:status(state, extra)
		local payload = { state = state, ts = self:now(), at = self:wall() }
		if type(extra) == 'table' then
			for k, v in pairs(extra) do payload[k] = v end
		end
		self.conn:retain(t('svc', self.name, 'status'), payload)
		self:obs_state('status', payload)
	end

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

	-- Wait for HAL announce (retained), return payload table.
	-- opts: { timeout?: number, tick?: number }
	function svc:wait_for_hal(opts2)
		opts2 = opts2 or {}
		local deadline_s  = (type(opts2.timeout) == 'number') and opts2.timeout or 60.0
		local tick_s      = (type(opts2.tick) == 'number') and opts2.tick or 10.0
		local deadline_at = self:now() + deadline_s

		self:obs_log('info', 'waiting for HAL announce on svc/hal/announce')
		self:status('waiting_for_hal', { deadline_s = deadline_s })

		local sub = self.conn:subscribe(t('svc', 'hal', 'announce'), { queue_len = 4, full = 'drop_oldest' })

		while true do
			if self:now() >= deadline_at then
				sub:unsubscribe()
				return nil, 'hal discovery timeout'
			end

			local which, a, b = perform(named_choice {
				recv = sub:recv_op(),
				tick = sleep.sleep_op(tick_s):wrap(function () return nil, 'waiting' end),
			})

			if which == 'tick' then
				self:obs_event('hal_waiting', { at = self:wall(), ts = self:now() })
			else
				local msg, err = a, b
				if not msg then
					sub:unsubscribe()
					return nil, err or 'hal discovery subscription closed'
				end

				local p = msg.payload or {}
				if p.role == 'hal' then
					self:obs_event('hal_discovered', {
						from  = topic_to_string(msg.topic),
						rpc   = topic_to_string(p.rpc_root or t('rpc', 'hal')),
						backend = p.backend,
					})
					sub:unsubscribe()
					return p, nil
				end
			end
		end
	end

	-- Fixed HAL RPC surface: rpc/hal/<method>
	function svc:hal_call(method, payload, timeout_s)
		local topic = t('rpc', 'hal', method)
		return perform(self.conn:call_op(topic, payload, { timeout = timeout_s }))
	end

	return svc
end

return M
