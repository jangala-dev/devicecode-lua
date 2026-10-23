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
        print('Run inside the devcontainer. Build/deploy valid, unsupported, and original modes. 2G is excluded.')
        print(support.help)
        print([[
  --imei IMEI               Test one modem; default all enabled modems
  --preferred MODE          Explicit valid pair (none, 3g, 4g or 5g); requires --allowed
  --allowed MODES           Comma-separated allowed generations; requires --preferred
  --ui-url URL              Box-local UI base URL, queried over SSH; default http://127.0.0.1:PORT
Without an explicit pair, prefer 4G-only or 4G-preferred pairs different from the original modes.
2G must be disabled in the original settings and is excluded from every test phase.
On success leave the new code running with the captured original modes explicitly configured.
On failure restore the saved runtime/configuration and original modem modes.]])
        return 0
    end
    io.stdout:setvbuf('no')
    return runner.new(args):run()
end)
if not ok then io.stderr:write('FAIL: ', tostring(code), '\n') end
os.exit(ok and code or 1)
