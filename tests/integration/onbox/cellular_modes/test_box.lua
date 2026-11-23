#!/usr/bin/env luajit
local posix = require 'posix'
local path = assert(posix.realpath(arg[0]))
local here = assert(path:match('^(.*)/[^/]+$'))
local repo = assert(here:match('^(.*)/tests/integration/onbox/cellular_modes$'))
package.path = repo .. '/tests/integration/?.lua;' .. repo .. '/src/?.lua;' .. package.path
local runner = require 'onbox.cellular_modes.runner'
local support = require 'onbox.support.runner'

local ok, code = pcall(function()
	local args = runner.parse_args(arg, repo, here)
	if args.help then
		print('Usage: luajit tests/integration/onbox/cellular_modes/test_box.lua [options]')
		print('Run inside the devcontainer. Verify mode changes, unsupported requests and safe restoration.')
		print(support.help)
		print([[
  --imei IMEI               Test one modem; default all enabled modems
  --preferred MODE          Explicit valid pair (none, 3g, 4g or 5g); requires --allowed
  --allowed MODES           Comma-separated allowed generations; requires --preferred
  --ui-url URL              Box-local UI base URL, queried over SSH; default http://127.0.0.1:PORT
The pair must differ from both the live modem modes and any configured pair.
Automatic selection prefers 4G-only, then combinations that prefer 4G.
2G may be present in live modes. The test applies only pairs without 2G.
After checking that an unsupported request leaves the modem unchanged, restore
the original pair if advertised and free of 2G. Otherwise keep the phase-one pair.
Teardown restores and verifies the original runtime and configuration.]])
		return 0
	end
	io.stdout:setvbuf('no')
	return runner.new(args):run()
end)
if not ok then io.stderr:write('FAIL: ', tostring(code), '\n') end
os.exit(ok and code or 1)
