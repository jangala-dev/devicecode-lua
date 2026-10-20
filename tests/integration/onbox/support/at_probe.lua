-- On-box helper: use the exact AT transport shipped in the deployed runtime.
local runtime, port = arg[1], arg[2]
assert(runtime and port and arg[3], 'usage: at_probe.lua RUNTIME AT_PORT COMMAND...')
package.path = runtime .. '/?.lua;' .. runtime .. '/?/init.lua;'
    .. runtime .. '/lib/?.lua;' .. runtime .. '/lib/?/init.lua;/usr/lib/lua/?.lua;' .. package.path

local fibers = require 'fibers'
local op = require 'fibers.op'
local sleep = require 'fibers.sleep'
local json = require 'cjson.safe'
local at = require 'services.hal.backends.modem.at'

fibers.run(function()
    ---@type table<string, ATResponseLine[]>
    local response = {}
    for i = 3, #arg do
        local command = arg[i]
        local which, lines, err = fibers.perform(op.named_choice({
            response = at.send_op(port, command),
            timeout = sleep.sleep_op(4),
        }))
        assert(which == 'response', command .. ' timed out')
        assert(lines and not err, command .. ': ' .. tostring(err))
        response[command] = lines
    end
    print(assert(json.encode(response)))
end)
