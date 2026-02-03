-- services/hal.lua
--
-- Stub HAL for early bring-up:
--   * announces rpc_root
--   * implements read_state/write_state for config/services
--   * serves a fixed JSON blob keyed by service name

local fibers  = require 'fibers'
local runtime = require 'fibers.runtime'
local sleep   = require 'fibers.sleep'

local perform = fibers.perform

local M       = {}

local function t(...) return { ... } end
local function now() return runtime.now() end
local function wall() return os.date('%Y-%m-%d %H:%M:%S') end

local function obs_log(conn, svc, level, payload)
	conn:publish(t('obs', 'log', svc, level), payload)
end

local function obs_event(conn, svc, name, payload)
	conn:publish(t('obs', 'event', svc, name), payload)
end

local function obs_state(conn, svc, name, payload)
	conn:retain(t('obs', 'state', svc, name), payload)
end

local function publish_status(conn, name, state, extra)
	local payload = { state = state, ts = now(), at = wall() }
	if type(extra) == 'table' then
		for k, v in pairs(extra) do payload[k] = v end
	end
	conn:retain(t('svc', name, 'status'), payload)
	obs_state(conn, name, 'status', payload)
end

local function reply_best_effort(conn, reply_to, payload, opts)
	local ok, reason = conn:publish_one(reply_to, payload, opts)
	return ok, reason
end

function M.start(conn, opts)
	opts = opts or {}
	local name = opts.name or 'hal'

	obs_log(conn, name, 'debug', 'start() entered')
	publish_status(conn, name, 'starting')

	local rpc_root = t('rpc', 'hal')

	-- Hard-coded initial config JSON blob; top-level keys are service names.
	-- Keep it valid JSON (double quotes, etc).
	local state_blob = [[
{
  "wifi":   { "enabled": true, "country": "GB" },
  "network":{ "wan": { "dhcp": true } },
  "monitor":{ "pretty": true }
}
]]

	-- Announce presence for discovery (config listens on svc/+/announce).
	conn:retain(t('svc', name, 'announce'), { role = 'hal', rpc_root = rpc_root })

	publish_status(conn, name, 'running', { rpc_root = 'rpc/hal' })
	obs_event(conn, name, 'ready', { rpc_root = 'rpc/hal' })
	obs_log(conn, name, 'info', 'stub hal start() entered')

	-- Heartbeat (optional, but consistent with your style).
	fibers.spawn(function()
		local n = 0
		while true do
			n = n + 1
			obs_event(conn, name, 'tick', { n = n, ts = now() })
			sleep.sleep(30.0)
		end
	end)

	-- Lane B endpoints.
	local ep_read  = conn:bind(t('rpc', 'hal', 'read_state'), { queue_len = 8 })
	local ep_write = conn:bind(t('rpc', 'hal', 'write_state'), { queue_len = 8 })

	local function handle(msg, method)
		obs_event(conn, name, 'rpc_in', { id = msg.id, method = method })

		local req = msg.payload or {}
		local reply

		if method == 'read_state' then
			if req.ns == 'config' and req.key == 'services' then
				reply = { ok = true, found = true, data = state_blob }
			else
				reply = { ok = true, found = false }
			end
		elseif method == 'write_state' then
			-- Accept writes; store in-memory only.
			if type(req.data) == 'string' then
				state_blob = req.data
				reply = { ok = true }
			else
				reply = { ok = false, err = 'data must be a string' }
			end
		else
			reply = { ok = false, err = 'unknown method' }
		end

		if msg.reply_to ~= nil then
			local ok, reason = reply_best_effort(conn, msg.reply_to, reply, { id = msg.id })
			obs_event(conn, name, 'rpc_out', {
				id = msg.id, method = method, ok = (ok == true), reason = reason
			})
		else
			obs_event(conn, name, 'rpc_out', { id = msg.id, method = method, ok = false, reason = 'no reply_to' })
		end
	end

	-- Serve loop (two endpoints).
	fibers.spawn(function()
		for msg in ep_read:iter() do
			handle(msg, 'read_state')
		end
	end)

	for msg in ep_write:iter() do
		handle(msg, 'write_state')
	end
end

return M
