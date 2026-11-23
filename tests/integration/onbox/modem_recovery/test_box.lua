#!/usr/bin/env luajit
local stdlib = require 'posix.stdlib'
local path = assert(stdlib.realpath(arg[0]))
local here = assert(path:match('^(.*)/[^/]+$'))
local repo = assert(here:match('^(.*)/tests/integration/onbox/modem_recovery$'))
package.path = repo .. '/tests/integration/?.lua;' .. repo .. '/src/?.lua;' .. package.path
local runner = require 'onbox.modem_reset.runner'
local support = require 'onbox.support.runner'

local ok, code = pcall(function()
	local args = runner.parse_args(arg, repo, here, true)
	if args.help then
		print('Usage: luajit tests/integration/onbox/modem_recovery/test_box.lua [options]')
		print('Time each modem from HAL reappearance through GSM connected and NET online.')
		print(support.help)
		print('  --imei IMEI                    Limit this run to one modem')
		print('  --max-connected-seconds SEC     Fail above this reappearance-to-connected time')
		print('  --max-online-seconds SEC        Fail above this reappearance-to-online time')
		return 0
	end
	io.stdout:setvbuf('no')
	return runner.new(args):run()
end)
if not ok then io.stderr:write('FAIL: ', tostring(code), '\n') end
os.exit(ok and code or 1)
