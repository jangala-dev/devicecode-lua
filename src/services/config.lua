-- services/config.lua
--
-- Config service:
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

local op      = require 'fibers.op'
local runtime = require 'fibers.runtime'
local perform = require 'fibers.performer'.perform

local cjson = require 'cjson.safe'

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

local function shallow_copy(x)
	local out = {}
	for k, v in pairs(x) do out[k] = v end
	return out
end

local function is_plain_table(x)
	return type(x) == 'table' and getmetatable(x) == nil
end

local function is_service_map(x)
	-- top-level: service_name -> settings_table
	if not is_plain_table(x) then return false end
	for k, v in pairs(x) do
		if type(k) ~= 'string' or k == '' then return false end
		if not is_plain_table(v) then return false end
	end
	return true
end

-------------------------------------------------------------------------------
-- HAL discovery + client
-------------------------------------------------------------------------------

local function discover_hal_rpc_root(conn)
	local sub = conn:subscribe(t('svc', '+', 'announce'), { queue_len = 10, full = 'drop_oldest' })

	while true do
		local msg, err = perform(sub:recv_op())
		if not msg then
			return nil, err
		end

		local p = msg.payload or {}
		if p.role == 'hal' and type(p.rpc_root) == 'table' then
			-- rpc_root is a topic array
			sub:unsubscribe()
			return p.rpc_root, nil
		end
	end
end

local function hal_call(conn, rpc_root, method, payload)
	local topic = { rpc_root[1], rpc_root[2], rpc_root[3], method }
	return conn:call(topic, payload)
end

local function hal_read_blob(conn, rpc_root, ns, key)
	local reply, err = hal_call(conn, rpc_root, 'read_state', { ns = ns, key = key })
	if not reply then return nil, err end
	if reply.ok ~= true then return nil, reply.err or 'hal read failed' end
	if reply.found ~= true then return nil, 'not_found' end
	return reply.data, nil
end

local function hal_write_blob(conn, rpc_root, ns, key, data)
	local reply, err = hal_call(conn, rpc_root, 'write_state', { ns = ns, key = key, data = data })
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

	publish_status(conn, name, 'starting')

	-- Discover HAL without naming it.
	local hal_rpc_root, herr = discover_hal_rpc_root(conn)
	if not hal_rpc_root then
		publish_status(conn, name, 'stopped', { reason = herr or 'no hal available' })
		return
	end

	local STATE_NS  = 'config'
	local STATE_KEY = 'services'

	-- Current config: service_name -> settings_table
	local current = {}

	local function publish_all_retained()
		for svc, settings in pairs(current) do
			conn:retain(t('config', svc), settings)
		end
	end

	local function load_from_hal()
		local blob, err = hal_read_blob(conn, hal_rpc_root, STATE_NS, STATE_KEY)
		if not blob then
			-- Missing is not fatal: start with empty.
			current = {}
			publish_all_retained()
			return true
		end

		local decoded = cjson.decode(blob)
		if not is_service_map(decoded) then
			-- Do not guess: publish nothing and surface an error status.
			publish_status(conn, name, 'degraded', { reason = 'invalid config JSON shape' })
			current = {}
			return true
		end

		current = decoded
		publish_all_retained()
		return true
	end

	local function persist_to_hal()
		local blob = cjson.encode(current) or '{}'
		local ok, err = hal_write_blob(conn, hal_rpc_root, STATE_NS, STATE_KEY, blob)
		if not ok then
			return nil, err
		end
		return true, nil
	end

	local function set_service(service, settings)
		if type(service) ~= 'string' or service == '' then
			return nil, 'invalid service'
		end
		if not is_plain_table(settings) then
			return nil, 'settings must be a table'
		end

		current[service] = settings
		local ok, err = persist_to_hal()
		if not ok then
			return nil, err
		end

		conn:retain(t('config', service), settings)
		return true, nil
	end

	-- Initial load
	load_from_hal()

	-- Updates from other sources (UI/cloud/etc)
	local sub_set = conn:subscribe(t('config', '+', 'set'), { queue_len = 50, full = 'drop_oldest' })

	publish_status(conn, name, 'running')

	while true do
		local msg, err = perform(sub_set:recv_op())
		if not msg then
			publish_status(conn, name, 'stopped', { reason = err })
			return
		end

		local service = msg.topic and msg.topic[2]
		local settings = msg.payload

		local ok, uerr = set_service(service, settings)
		-- Best-effort reply if request-style publish provided reply_to.
		if msg.reply_to ~= nil then
			if ok then
				conn:publish_one(msg.reply_to, { ok = true }, { id = msg.id })
			else
				conn:publish_one(msg.reply_to, { ok = false, err = tostring(uerr) }, { id = msg.id })
			end
		end
	end
end

return M
