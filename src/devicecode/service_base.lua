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

local DEFAULT_OBS_VERSION = 'v1'

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
---@param opts? { name?: string, env?: string, version?: string }
---@return ServiceBase
function M.new(conn, opts)
	opts = opts or {}

	---@class ServiceBase
	local svc = {}

	svc.conn = conn
	svc.name = opts.name or 'service'
	svc.env  = opts.env or (os.getenv('DEVICECODE_ENV') or 'dev')
	svc.version = opts.version or DEFAULT_OBS_VERSION

	function svc:now() return runtime.now() end
	function svc:wall() return wall() end
	function svc:t(...) return t(...) end
	function svc:topic_to_string(topic) return topic_to_string(topic) end

	function svc:obs_log(level, payload)
		self.conn:publish(t('obs', self.version, 'log', self.name, level), payload)
	end

	function svc:obs_event(name, payload)
		self.conn:publish(t('obs', self.version, 'event', self.name, name), payload)
	end

	function svc:obs_metric(name, payload)
		self.conn:publish(t('obs', self.version, 'metric', self.name, name), payload)
	end

	function svc:obs_state(name, payload)
		self.conn:retain(t('obs', self.version, 'state', self.name, name), payload)
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

	return svc
end

return M
