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
	-- Include system Lua paths for OpenWrt packages (e.g. http.request, ssl, etc.)
	add_path('/usr/share/lua/')
	add_path('/usr/lib/lua/')
else
	add_path('../vendor/lua-fibers/src/')
	add_path('../vendor/lua-bus/src/')
	add_path('../vendor/lua-trie/src/')
	add_path('./')
	-- Include system Lua paths for locally-installed packages (e.g. http.request)
	add_path('/usr/share/lua/')
	add_path('/usr/lib/lua/')
end

local fibers = require 'fibers'
local op = require 'fibers.op'
local sleep  = require 'fibers.sleep'
local scope = require 'fibers.scope'
local busmod = require 'bus'
local log = require 'services.log'

if env == 'dev' then
	scope.set_debug(true) -- enable debug mode for better error traces
end

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
	require_env('DEVICECODE_CONFIG_DIR')
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

	local scopes = {}

	for i = 1, #service_names do
		local name = service_names[i]
		local mod  = require('services.' .. name)

		local s = root:child(name)
		s:spawn(function ()
			print("main: spawning: "..tostring(name))
			local conn = bus:connect() -- created inside the service scope
			mod.start(conn, { name = name })
		end)
		scopes[name] = s
	end

	-- Keep alive until scope cancellation.
	while true do
		local ops = {}
		for name, s in pairs(scopes) do
			ops[#ops + 1] = s:fault_op():wrap(function (_, pr)
				return { name = name, scope = s, pr = pr }
			end)
		end
		local source, msg, err = fibers.perform(op.named_choice(ops))

		if source then
			log.error("main", "service", msg.name, "failed with error:", msg.pr)
			fibers.perform(msg.scope:join_op())
			scopes[msg.name] = nil
		else
			log.error("main", "error in main loop:", err)
		end
	end
end)
