-- services/config.lua
--
-- Config service:
--  - discovers filesystem capability {'cap', 'fs', 'config', ...}
--  - reads config.json from the filesystem capability
--  - publishes retained to {'cfg', <service_name>} with the nested settings table
--  - accepts updates (in-memory only, not persisted):
--      * pub/sub: {'cfg', <service_name>, 'set'} payload is a table (settings)
--
-- Config file location: ${DC_CONFIG_DIR}/config.json
-- Format: { "service_name": { ...settings... }, ... }
--
-- Note: Write/persistence not yet implemented.

local op      = require 'fibers.op'
local runtime = require 'fibers.runtime'
local perform = require 'fibers.performer'.perform
local log     = require 'services.log'

local cjson = require 'cjson.safe'
local external_types = require 'services.hal.types.external'

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
-- Filesystem capability discovery + client
-------------------------------------------------------------------------------

local function wait_for_fs_capability(conn)
	-- Wait for filesystem capability with ID 'config' to become available
	local sub = conn:subscribe(t('cap', 'fs', 'config', 'state'), { queue_len = 10, full = 'drop_oldest' })

	while true do
		local msg, err = perform(sub:recv_op())
		if not msg then
			return nil, err
		end

		if msg.payload == 'added' then
			sub:unsubscribe()
			return true, nil
		end
	end
end

local function fs_read_config(conn)
	-- Read config.json from the filesystem capability
	local opts, opts_err = external_types.new.FilesystemReadOpts('config.json')
	if not opts then
		return nil, 'failed to create read options: ' .. tostring(opts_err)
	end

	local reply, err = conn:call(t('cap', 'fs', 'config', 'rpc', 'read'), opts)
	if not reply then
		return nil, err
	end

	if reply.ok ~= true then
		return nil, reply.reason or 'filesystem read failed'
	end

	-- File content is in reply.reason
	return reply.reason, nil
end

-------------------------------------------------------------------------------
-- Service
-------------------------------------------------------------------------------

function M.start(conn, opts)
	opts = opts or {}
	local name = opts.name or 'config'

	publish_status(conn, name, 'starting')

	-- Wait for filesystem capability to become available
	local ok, cap_err = wait_for_fs_capability(conn)
	if not ok then
		publish_status(conn, name, 'stopped', { reason = cap_err or 'filesystem capability not available' })
		return
	end

	-- Current config: service_name -> settings_table
	local current = {}

	local function publish_all_retained()
		for svc, settings in pairs(current) do
			conn:retain(t('cfg', svc), settings)
		end
	end

	local function load_from_fs()
		local blob, err = fs_read_config(conn)
		if not blob then
			log.warn(("Config: %s"):format(err))
			-- Missing file is not fatal: start with empty config.
			if err and (err:find('not found') or err:find('No such file')) then
				current = {}
				publish_all_retained()
				return true
			end
			-- Other errors are more serious
			publish_status(conn, name, 'degraded', { reason = 'failed to read config: ' .. tostring(err) })
			current = {}
			return false
		end

		local decoded = cjson.decode(blob)
		print(decoded)
		if not is_service_map(decoded) then
			-- Do not guess: publish nothing and surface an error status.
			publish_status(conn, name, 'degraded', { reason = 'invalid config JSON shape' })
			current = {}
			return false
		end

		current = decoded
		publish_all_retained()
		return true
	end

	local function set_service(service, settings)
		if type(service) ~= 'string' or service == '' then
			return nil, 'invalid service'
		end
		if not is_plain_table(settings) then
			return nil, 'settings must be a table'
		end

		-- Update in-memory only (persistence not yet implemented)
		current[service] = settings
		conn:retain(t('cfg', service), settings)
		return true, nil
	end

	-- Initial load
	load_from_fs()

	-- Updates from other sources (UI/cloud/etc)
	local sub_set = conn:subscribe(t('cfg', '+', 'set'), { queue_len = 50, full = 'drop_oldest' })

	publish_status(conn, name, 'running')

	while true do
		local msg, err = perform(sub_set:recv_op())
		if not msg then
			publish_status(conn, name, 'stopped', { reason = err })
			return
		end

		local service = msg.topic and msg.topic[2]
		local settings = msg.payload

		local success, uerr = set_service(service, settings)
		-- Best-effort reply if request-style publish provided reply_to.
		if msg.reply_to ~= nil then
			if success then
				conn:publish_one(msg.reply_to, { ok = true }, { id = msg.id })
			else
				conn:publish_one(msg.reply_to, { ok = false, err = tostring(uerr) }, { id = msg.id })
			end
		end
	end
end

return M
