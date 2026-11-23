#!/usr/bin/env luajit
local stdlib = require 'posix.stdlib'
local path = assert(stdlib.realpath(arg[0]))
local here = assert(path:match('^(.*)/[^/]+$'))
local repo = assert(here:match('^(.*)/tests/integration/onbox/speedtest_compare$'))
package.path = repo .. '/tests/integration/?.lua;' .. repo .. '/src/?.lua;' .. package.path
local runner = require 'onbox.speedtest_compare.runner'
local support = require 'onbox.support.runner'

local ok, code = pcall(function()
	local args = runner.parse_args(arg, repo, here)
	if args.help then
		print('Usage: luajit tests/integration/onbox/speedtest_compare/test_box.lua [options]')
		print('Compare Devicecode and Speedtest CLI download results on each online WAN path.')
		print(support.help)
		print('  --settle-seconds SECONDS  WAN discovery window after NET is ready (default 60)')
		print('  --server-id ID            Use this LibreSpeed server for each CLI run')
		return 0
	end
	io.stdout:setvbuf('no')
	return runner.new(args):run()
end)
if not ok then io.stderr:write('FAIL: ', tostring(code), '\n') end
os.exit(ok and code or 1)
