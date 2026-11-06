#!/usr/bin/env luajit
local posix = require 'posix'
local path = assert(posix.realpath(arg[0]))
local here = assert(path:match('^(.*)/[^/]+$'))
local repo = assert(here:match('^(.*)/tests/integration/onbox/modem_pdp$'))
package.path = repo .. '/tests/integration/?.lua;' .. repo .. '/src/?.lua;' .. package.path
local runner = require 'onbox.modem_pdp.runner'
local support = require 'onbox.support.runner'
local ok, code = pcall(function()
    local args = runner.parse_args(arg, repo, here)
    if args.help then
        print('Usage: luajit tests/integration/onbox/modem_pdp/test_box.lua [options]')
        print('Run inside the devcontainer. Build, deploy, and verify IP then IPV4V6 on the box.')
        print(support.help)
        print([[
  --first TYPE              Default IP
  --second TYPE             Default IPV4V6
  --keep-final-config       Leave the second PDP config active
By default restore the original modem config, keeping the new code deployed.]])
        print('A modem without an AT port is reset immediately, with up to two recovery resets per wait.')
        return 0
    end
    io.stdout:setvbuf('no')
    return runner.new(args):run()
end)
if not ok then io.stderr:write('FAIL: ', tostring(code), '\n') end
os.exit(ok and code or 1)
