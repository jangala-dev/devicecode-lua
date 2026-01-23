-- main.lua
--
-- Entrypoint.
--
-- Required env:
--   DEVICECODE_SERVICES   comma-separated service module names (e.g. "hal,config,monitor")
--   DEVICECODE_STATE_DIR  persisted state root directory
--
-- Optional env:
--   DEVICECODE_ENV        "dev" | "prod" (default: dev)

local function add_path(prefix)
	package.path = prefix .. '?.lua;' .. prefix .. '?/init.lua;' .. package.path
end

local env = os.getenv('DEVICECODE_ENV') or 'dev'
if env == 'prod' then
	add_path('./lib/')
else
	add_path('../vendor/lua-fibers/src/')
	add_path('../vendor/lua-bus/src/')
	add_path('../vendor/lua-trie/src/')
	add_path('./')
end

local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'
local busmod = require 'bus'

local function require_env(name)
	local v = os.getenv(name)
	if not v or v == '' then
		error(('missing required environment variable %s'):format(name), 2)
	end
	return v
end

local function parse_csv(s)
	local out = {}
	for part in tostring(s):gmatch('[^,%s]+') do
		out[#out + 1] = part
	end
	return out
end

fibers.run(function ()
	print("main: starting")
	local root = fibers.current_scope()

	-- Validate required env early.
	require_env('DEVICECODE_STATE_DIR')
	local service_names = parse_csv(require_env('DEVICECODE_SERVICES'))
	if #service_names == 0 then
		error('DEVICECODE_SERVICES must contain at least one service name', 2)
	end

	local bus = busmod.new({
		q_length = 10,
		full     = 'drop_oldest',
		s_wild   = '+',
		m_wild   = '#',
	})

	for i = 1, #service_names do
		local name = service_names[i]
		local mod  = require('services.' .. name)

		local s = root:child(name)
		s:spawn(function ()
			print("main: spawning: "..tostring(name))
			local conn = bus:connect() -- created inside the service scope
			mod.start(conn, { name = name })
		end)
	end

	-- Keep alive until scope cancellation.
	sleep.sleep(math.huge)
end)
