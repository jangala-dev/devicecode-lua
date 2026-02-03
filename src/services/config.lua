-- services/config.lua
--
-- Config service (chatty version):
--  - discovers HAL via {'svc','+','announce'} where payload.role == "hal"
--  - reads a single JSON blob from HAL (string) keyed at top level by service name
--  - publishes retained to {'config', <service_name>} with the nested settings table
--  - accepts updates:
--      * pub/sub: {'config', <service_name>, 'set'} payload is a table (settings)
--
-- Persisted state location (within HAL):
--   ns  = "config"
--   key = "services"
--
-- Assumes cjson.safe is available.

local fibers  = require 'fibers'
local runtime = require 'fibers.runtime'
local sleep   = require 'fibers.sleep'

local cjson = require 'cjson.safe'

local perform      = fibers.perform
local named_choice = fibers.named_choice

local M = {}

local function t(...)
	return { ... }
end

local function now()
	return runtime.now()
end

local function wall_time()
	return os.date('%Y-%m-%d %H:%M:%S')
end

-------------------------------------------------------------------------------
-- Observability helpers
-------------------------------------------------------------------------------

local function obs_log(conn, svc, level, payload)
	conn:publish(t('obs', 'log', svc, level), payload)
end

local function obs_event(conn, svc, name, payload)
	conn:publish(t('obs', 'event', svc, name), payload)
end

local function obs_state(conn, svc, name, payload)
	conn:retain(t('obs', 'state', svc, name), payload)
end

local function topic_to_string(topic)
	if type(topic) ~= 'table' then return tostring(topic) end
	local parts = {}
	for i = 1, #topic do parts[#parts + 1] = tostring(topic[i]) end
	return table.concat(parts, '/')
end

-------------------------------------------------------------------------------
-- Status publishing
-------------------------------------------------------------------------------

local function publish_status(conn, name, state, extra)
	local payload = { state = state, ts = now(), at = wall_time() }
	if type(extra) == 'table' then
		for k, v in pairs(extra) do payload[k] = v end
	end

	conn:retain(t('svc', name, 'status'), payload)
	obs_state(conn, name, 'status', payload)
end

local function is_plain_table(x)
	return type(x) == 'table' and getmetatable(x) == nil
end

local function is_service_map(x)
	if not is_plain_table(x) then return false end
	for k, v in pairs(x) do
		if type(k) ~= 'string' or k == '' then return false end
		if not is_plain_table(v) then return false end
	end
	return true
end

local function count_pairs(tbl)
	local n = 0
	for _ in pairs(tbl) do n = n + 1 end
	return n
end

-------------------------------------------------------------------------------
-- HAL discovery + client
-------------------------------------------------------------------------------

local function join_topic(root, last)
	local out = {}
	for i = 1, #root do out[i] = root[i] end
	out[#out + 1] = last
	return out
end

local function discover_hal_rpc_root(conn, name, opts)
	opts = opts or {}

	local deadline_s  = (type(opts.timeout) == 'number') and opts.timeout or 60.0
	local tick_s      = (type(opts.tick) == 'number') and opts.tick or 10.0
	local deadline_at = now() + deadline_s

	obs_log(conn, name, 'info', 'waiting for HAL announce on svc/+/announce')

	local sub = conn:subscribe(t('svc', '+', 'announce'), { queue_len = 10, full = 'drop_oldest' })
	publish_status(conn, name, 'waiting_for_hal', { deadline_s = deadline_s })

	while true do
		if now() >= deadline_at then
			sub:unsubscribe()
			return nil, 'hal discovery timeout'
		end

		local which, a, b = perform(named_choice {
			recv = sub:recv_op(),
			tick = sleep.sleep_op(tick_s):wrap(function () return nil, 'waiting' end),
		})

		if which == 'tick' then
			obs_event(conn, name, 'hal_waiting', { at = wall_time(), ts = now() })
		else
			local msg, err = a, b
			if not msg then
				sub:unsubscribe()
				return nil, err or 'hal discovery subscription closed'
			end

			local p = msg.payload or {}
			if p.role == 'hal' and type(p.rpc_root) == 'table' then
				obs_event(conn, name, 'hal_discovered', {
					rpc_root = topic_to_string(p.rpc_root),
					from     = topic_to_string(msg.topic),
				})
				sub:unsubscribe()
				return p.rpc_root, nil
			end
		end
	end
end

local function hal_call(conn, rpc_root, method, payload, timeout_s)
	local topic = join_topic(rpc_root, method)
	return perform(conn:call_op(topic, payload, { timeout = timeout_s }))
end

local function hal_read_blob(conn, rpc_root, ns, key)
	local reply, err = hal_call(conn, rpc_root, 'read_state', { ns = ns, key = key }, 2.0)
	if not reply then return nil, err end
	if reply.ok ~= true then return nil, reply.err or 'hal read failed' end
	if reply.found ~= true then return nil, 'not_found' end
	return reply.data, nil
end

local function hal_write_blob(conn, rpc_root, ns, key, data)
	local reply, err = hal_call(conn, rpc_root, 'write_state', { ns = ns, key = key, data = data }, 4.0)
	if not reply then return nil, err end
	if reply.ok ~= true then return nil, reply.err or 'hal write failed' end
	return true, nil
end

-------------------------------------------------------------------------------
-- Service
-------------------------------------------------------------------------------

function M.start(conn, opts)
	opts = opts or {}
	local name = opts.name or 'config'

	obs_state(conn, name, 'boot', { at = wall_time(), ts = now(), state = 'entered' })
	obs_log(conn, name, 'info', 'service start() entered')
	publish_status(conn, name, 'starting')

	-- Heartbeat (simple; cancellation interrupts sleep naturally).
	fibers.spawn(function ()
		local n = 0
		while true do
			n = n + 1
			obs_event(conn, name, 'tick', { n = n, ts = now() })
			sleep.sleep(30.0)
		end
	end)

	-- Discover HAL.
	local hal_rpc_root, herr = discover_hal_rpc_root(conn, name, { timeout = 60, tick = 10 })
	if not hal_rpc_root then
		publish_status(conn, name, 'stopped', { reason = herr or 'no hal available' })
		obs_log(conn, name, 'error', { what = 'start_failed', err = tostring(herr or 'no hal') })
		return
	end

	local STATE_NS  = 'config'
	local STATE_KEY = 'services'

	local current = {}

	local function publish_all_retained()
		local n = 0
		for svc, settings in pairs(current) do
			n = n + 1
			conn:retain(t('config', svc), settings)
		end
		obs_event(conn, name, 'publish_all', { services = n })
	end

	local function load_from_hal()
		obs_event(conn, name, 'load_begin', { ns = STATE_NS, key = STATE_KEY })

		local blob, err = hal_read_blob(conn, hal_rpc_root, STATE_NS, STATE_KEY)
		if not blob then
			if err == 'not_found' then
				obs_log(conn, name, 'warn', { what = 'load_missing', ns = STATE_NS, key = STATE_KEY })
			else
				obs_log(conn, name, 'error', { what = 'load_failed', err = tostring(err), ns = STATE_NS, key = STATE_KEY })
			end
			current = {}
			publish_all_retained()
			obs_event(conn, name, 'load_end', { ok = true, services = 0 })
			return true
		end

		local decoded, jerr = cjson.decode(blob)
		if decoded == nil then
			publish_status(conn, name, 'degraded', { reason = 'invalid config JSON', err = tostring(jerr) })
			obs_log(conn, name, 'error', { what = 'json_decode_failed', err = tostring(jerr) })
			current = {}
			obs_event(conn, name, 'load_end', { ok = false, reason = 'decode_failed' })
			return true
		end

		if not is_service_map(decoded) then
			publish_status(conn, name, 'degraded', { reason = 'invalid config JSON shape' })
			obs_log(conn, name, 'error', { what = 'invalid_shape' })
			current = {}
			obs_event(conn, name, 'load_end', { ok = false, reason = 'invalid_shape' })
			return true
		end

		current = decoded
		publish_all_retained()
		obs_event(conn, name, 'load_end', { ok = true })
		return true
	end

	local function persist_to_hal(reason)
		local blob = cjson.encode(current) or '{}'
		obs_event(conn, name, 'persist_begin', { ns = STATE_NS, key = STATE_KEY, reason = reason })

		local ok, err = hal_write_blob(conn, hal_rpc_root, STATE_NS, STATE_KEY, blob)
		if not ok then
			obs_log(conn, name, 'error', { what = 'persist_failed', err = tostring(err) })
			obs_event(conn, name, 'persist_end', { ok = false, err = tostring(err) })
			return nil, err
		end

		obs_event(conn, name, 'persist_end', { ok = true })
		return true, nil
	end

	local function set_service(service, settings, msg)
		if type(service) ~= 'string' or service == '' then
			return nil, 'invalid service'
		end
		if not is_plain_table(settings) then
			return nil, 'settings must be a table'
		end

		obs_event(conn, name, 'set_received', {
			service  = service,
			keys     = count_pairs(settings),
			reply_to = msg and msg.reply_to and topic_to_string(msg.reply_to) or nil,
			id       = msg and msg.id or nil,
		})

		local old = current[service]
		current[service] = settings

		local ok, err = persist_to_hal('set ' .. service)
		if not ok then
			current[service] = old
			return nil, err
		end

		conn:retain(t('config', service), settings)
		obs_event(conn, name, 'set_applied', { service = service })
		return true, nil
	end

	-- Initial load.
	load_from_hal()

	-- Updates from other sources.
	local sub_set = conn:subscribe(t('config', '+', 'set'), { queue_len = 50, full = 'drop_oldest' })
	obs_log(conn, name, 'info', 'subscribed to config/+/set')

	publish_status(conn, name, 'running')
	obs_log(conn, name, 'info', 'service running')

	while true do
		local msg, err = perform(sub_set:recv_op())
		if not msg then
			publish_status(conn, name, 'stopped', { reason = err })
			obs_log(conn, name, 'warn', { what = 'subscription_ended', err = tostring(err) })
			return
		end

		local service  = msg.topic and msg.topic[2]
		local settings = msg.payload

		obs_event(conn, name, 'set_message', {
			service  = tostring(service),
			reply_to = msg.reply_to and topic_to_string(msg.reply_to) or nil,
			id       = msg.id,
		})

		local ok, uerr = set_service(service, settings, msg)

		if msg.reply_to ~= nil then
			local payload = ok and { ok = true } or { ok = false, err = tostring(uerr) }
			local rok, rreason = conn:publish_one(msg.reply_to, payload, { id = msg.id })
			if not rok then
				obs_log(conn, name, 'warn', { what = 'reply_failed', reason = tostring(rreason) })
			end
		end

		if not ok then
			obs_log(conn, name, 'warn', { what = 'set_rejected', service = tostring(service), err = tostring(uerr) })
		end
	end
end

return M
