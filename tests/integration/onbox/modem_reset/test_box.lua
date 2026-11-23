#!/usr/bin/env luajit
local stdlib = require 'posix.stdlib'
local path = assert(stdlib.realpath(arg[0]))
local here = assert(path:match('^(.*)/[^/]+$'))
local repo = assert(here:match('^(.*)/tests/integration/onbox/modem_reset$'))
package.path = repo .. '/tests/integration/?.lua;' .. repo .. '/src/?.lua;' .. package.path
local runner = require 'onbox.modem_reset.runner'
local support = require 'onbox.support.runner'

local ok, code = pcall(function()
	local args = runner.parse_args(arg, repo, here)
	if args.help then
		print('Usage: luajit tests/integration/onbox/modem_reset/test_box.lua [options]')
		print('Reset each connected modem in turn and verify its removal and return in HAL and GSM.')
		print(support.help)
		print('  --imei IMEI               Limit this run to one connected modem')
		return 0
	end
	io.stdout:setvbuf('no')
	return runner.new(args):run()
end)
if not ok then io.stderr:write('FAIL: ', tostring(code), '\n') end
os.exit(ok and code or 1)
