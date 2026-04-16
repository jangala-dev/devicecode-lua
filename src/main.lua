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
if env == 'prod' then
	add_path('./lib/')
else
	add_path('../vendor/lua-fibers/src/')
	add_path('../vendor/lua-bus/src/')
	add_path('../vendor/lua-trie/src/')
	add_path('./')
end

package.path  = '/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua;' .. package.path
package.cpath = '/usr/lib/lua/?.so;' .. package.cpath

local fibers         = require 'fibers'
local mainmod        = require 'devicecode.main'
local http_transport = require 'services.ui.http_transport'

-- ui service requires opts.run_http but origin/ui-migration never wired it up.
fibers.run(function(scope)
	return mainmod.run(scope, {
		env = env,
		service_opts = {
			ui = { run_http = http_transport.run },
		},
	})
end)
