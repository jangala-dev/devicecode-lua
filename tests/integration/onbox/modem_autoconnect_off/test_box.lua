#!/usr/bin/env luajit
local stdlib = require 'posix.stdlib'
local path = assert(stdlib.realpath(arg[0]))
local here = assert(path:match('^(.*)/[^/]+$'))
local repo = assert(here:match('^(.*)/tests/integration/onbox/modem_autoconnect_off$'))
package.path = repo .. '/tests/integration/?.lua;' .. repo .. '/src/?.lua;' .. package.path
local runner = require 'onbox.modem_autoconnect_off.runner'
local support = require 'onbox.support.runner'

local ok, code = pcall(function()
	local args = runner.parse_args(arg, repo, here)
	if args.help then
		print('Usage: luajit tests/integration/onbox/modem_autoconnect_off/test_box.lua [options]')
		print('Turn off autoconnect, reset all detected modems, and verify they stay disabled after startup.')
		print(support.help)
		print('  --observe-seconds SECONDS  Time to observe after GSM reports all disabled (default 60)')
		return 0
	end
	io.stdout:setvbuf('no')
	return runner.new(args):run()
end)
if not ok then io.stderr:write('FAIL: ', tostring(code), '\n') end
os.exit(ok and code or 1)
