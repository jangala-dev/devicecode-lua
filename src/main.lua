-- main.lua
--
-- Bootstrap entrypoint.
--
-- Required env:
--   DEVICECODE_SERVICES     comma-separated service module names (e.g. "hal,config,fabric,ui")
--   DEVICECODE_CONFIG_DIR   directory containing ${CONFIG_TARGET}.json
--   CONFIG_TARGET           config file stem (e.g. "mcu-dev" for mcu-dev.json)
--
-- Optional env:
--   DEVICECODE_ENV             "dev" | "prod" (default: dev)
--   DEVICECODE_NODE_ID         fabric session node id (default: "devicecode")
--   DEVICECODE_UI_HTTP_PORT    HTTP listener port for the ui service (default: 80)
--   DEVICECODE_UI_HTTP_HOST    HTTP bind host for the ui service   (default: 0.0.0.0)

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
local mainmod = require 'devicecode.main'

-- Inject default real-transport callbacks for services that need them.
-- Integration tests pass service_opts directly via mainmod.run and never
-- hit this path, so these defaults only apply to production runs.
local function default_service_opts()
	local out = {}

	local services_csv = os.getenv('DEVICECODE_SERVICES') or ''
	local has_ui = false
	for name in services_csv:gmatch('[^,%s]+') do
		if name == 'ui' then
			has_ui = true
			break
		end
	end

	if has_ui then
		local http_transport = require 'services.ui.http_transport'
		local port = tonumber(os.getenv('DEVICECODE_UI_HTTP_PORT'))
		local host = os.getenv('DEVICECODE_UI_HTTP_HOST')
		out.ui = {
			run_http = http_transport.run_http,
			port     = port,
			host     = (host ~= nil and host ~= '') and host or nil,
		}
	end

	return out
end

fibers.run(function(scope)
	return mainmod.run(scope, {
		env          = env,
		service_opts = default_service_opts(),
	})
end)
