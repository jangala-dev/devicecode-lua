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
--   DEVICECODE_CONFIG     selected config name (same effect as argv[1])

local function add_path(prefix)
	package.path = prefix .. '?.lua;' .. prefix .. '?/init.lua;' .. package.path
end

local function script_dir()
	local script = arg and arg[0] or ''
	local dir = script:match('^(.*[/\\])')
	if dir then
		return dir
	end
	return './'
end

local root = script_dir() .. '../'
local env = os.getenv('DEVICECODE_ENV') or 'dev'
if env == 'prod' then
	add_path(root .. 'lib/')
else
	add_path(root .. 'vendor/lua-fibers/src/')
	add_path(root .. 'vendor/lua-bus/src/')
	add_path(root .. 'vendor/lua-trie/src/')
	add_path(script_dir())
end

local fibers = require 'fibers'
local mainmod = require 'devicecode.main'
local config_name = arg and arg[1] or nil

fibers.run(function(scope)
	return mainmod.run(scope, {
		env         = env,
		config_name = config_name,
	})
end)
