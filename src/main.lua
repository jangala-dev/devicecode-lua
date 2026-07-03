-- main.lua
--
-- Bootstrap entrypoint.
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
add_path('/usr/lib/lua/')
add_path('./')
if env == 'prod' then
	add_path('./lib/')
else
	add_path('../vendor/lua-fibers/src/')
	add_path('../vendor/lua-bus/src/')
	add_path('../vendor/lua-trie/src/')
end

local fibers = require 'fibers'
local mainmod = require 'devicecode.main'
local signal_bridge = require 'devicecode.signal_bridge'

local ok, err = xpcall(function()
	return fibers.run(function(scope)
		local sig_ok, sig_err = signal_bridge.install(scope, {
			TERM = true,
			INT = true,
		})
		if not sig_ok then
			io.stderr:write('devicecode: signal bridge disabled: ' .. tostring(sig_err) .. '\n')
		end

		return mainmod.run(scope, {
			env = env,
		})
	end)
end, tostring)

if not ok then
	if tostring(err):match('signal:TERM') or tostring(err):match('signal:INT') then
		os.exit(0)
	end
	error(err, 0)
end
