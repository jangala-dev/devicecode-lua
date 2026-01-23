-- services/monitor.lua
--
-- Monitor service:
--  - subscribes to {'svc','+','status'} and keeps last status per service
--  - periodically publishes retained snapshot to {'monitor','services'}
--
-- Optional env:
--   DEVICECODE_MON_INTERVAL  seconds (default: 5)

local op      = require 'fibers.op'
local runtime = require 'fibers.runtime'
local sleep   = require 'fibers.sleep'
local perform = require 'fibers.performer'.perform

local M = {}

local function t(...)
	return { ... }
end

local function now()
	return runtime.now()
end

local function publish_status(conn, name, state, extra)
	local payload = { state = state, ts = now() }
	if type(extra) == 'table' then
		for k, v in pairs(extra) do payload[k] = v end
	end
	conn:retain(t('svc', name, 'status'), payload)
end

local function num_env(name, dflt)
	local v = os.getenv(name)
	if not v or v == '' then return dflt end
	local n = tonumber(v)
	if not n or n <= 0 then return dflt end
	return n
end

function M.start(conn, opts)
	opts = opts or {}
	local name = opts.name or 'monitor'
	local interval_s = num_env('DEVICECODE_MON_INTERVAL', 5)

	publish_status(conn, name, 'starting', { interval_s = interval_s })

	local sub_status = conn:subscribe(t('svc', '+', 'status'), { queue_len = 100, full = 'drop_oldest' })

	local seen = {} -- service_name -> payload

	local function publish_snapshot()
		local snap = { ts = now(), services = {} }
		for svc, payload in pairs(seen) do
			snap.services[svc] = payload
		end
		conn:retain(t('monitor', 'services'), snap)
	end

	publish_status(conn, name, 'running')

	while true do
		local which, a, b = perform(op.named_choice({
			status = sub_status:recv_op(),
			tick   = sleep.sleep_op(interval_s):wrap(function () return true end),
		}))

		if which == 'status' then
			local msg, err = a, b
			if not msg then
				publish_status(conn, name, 'stopped', { reason = err })
				return
			end
			local svc = msg.topic and msg.topic[2]
			if type(svc) == 'string' and svc ~= '' then
				seen[svc] = msg.payload or {}
			end

		elseif which == 'tick' then
			publish_snapshot()
		end
	end
end

return M
