-- services/hal/backends/network/providers/openwrt/hotplug_client.lua
--
-- Tiny hotplug/MWAN3 event forwarder.  It is intentionally dumb: it captures
-- environment supplied by procd/mwan3 and writes one JSON line to the provider's
-- UNIX socket.  Policy and snapshotting stay in the OpenWrt provider.

local socket = require 'fibers.io.socket'
local cjson = require 'cjson.safe'

local M = {}

local COMMON_ENV_KEYS = {
	'ACTION', 'INTERFACE', 'DEVICE', 'DEVICENAME', 'DEVNAME', 'DEVPATH', 'DEVTYPE',
	'SUBSYSTEM', 'SEQNUM', 'IFINDEX', 'IFUPDATE_ADDRESSES', 'IFUPDATE_ROUTES',
	'IFUPDATE_PREFIXES', 'IFUPDATE_DATA', 'PRODUCT', 'BUSNUM', 'DEVNUM', 'TYPE',
}

local function copy_env(env)
	local out = {}
	for k, v in pairs(env or {}) do
		if type(k) == 'string' and type(v) == 'string' then out[k] = v end
	end
	return out
end

local function process_env()
	local out = {}
	for i = 1, #COMMON_ENV_KEYS do
		local k = COMMON_ENV_KEYS[i]
		local v = os.getenv(k)
		if v ~= nil then out[k] = v end
	end
	return out
end

local function argv_opts(argv)
	local opts = {}
	for i = 1, #(argv or {}) do
		local a = tostring(argv[i] or '')
		local k, v = a:match('^%-%-([^=]+)=(.*)$')
		if k then opts[k] = v end
	end
	return opts
end

function M.send(record, opts)
	opts = opts or {}
	local path = opts.socket_path or os.getenv('DEVICECODE_NET_HOTPLUG_SOCKET') or '/var/run/devicecode-net-observe.sock'
	local line = cjson.encode(record or {})
	if type(line) ~= 'string' then return nil, 'encode failed' end
	local st, err = socket.connect_unix(path)
	if not st then return nil, err end
	local ok, werr = st:write(line .. '\n')
	if st.flush then st:flush() end
	st:close()
	if not ok then return nil, werr end
	return true, nil
end

function M.record_from_env(kind, directory, env)
	return {
		source = kind or 'hotplug',
		kind = kind or 'hotplug',
		directory = directory,
		env = copy_env(env or process_env()),
	}
end

function M.main(argv, env)
	argv = argv or arg or {}
	env = env or process_env()
	-- Lua cannot portably enumerate process environment.  Shell wrappers should
	-- pass the relevant variables in argv as --KEY=value, but tests may pass env.
	local opts = argv_opts(argv)
	local record = {
		source = opts.source or opts.kind or 'hotplug',
		kind = opts.kind or opts.source or 'hotplug',
		directory = opts.directory or opts.dir,
		env = {},
	}
	for k, v in pairs(env) do record.env[k] = v end
	for k, v in pairs(opts) do
		if k ~= 'socket' and k ~= 'socket_path' and k ~= 'kind' and k ~= 'source' and k ~= 'directory' and k ~= 'dir' then
			record.env[k] = v
		end
	end
	return M.send(record, { socket_path = opts.socket or opts.socket_path })
end

return M
