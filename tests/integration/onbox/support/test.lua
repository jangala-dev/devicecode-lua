#!/usr/bin/env luajit
-- Offline checks for shared on-box support; no box or password file is accessed.
local posix = require 'posix'
local path = assert(posix.realpath(arg[0]))
local here = assert(path:match('^(.*)/[^/]+$'))
local repo = assert(here:match('^(.*)/tests/integration/onbox/support$'))
package.path = repo .. '/tests/integration/?.lua;' .. repo .. '/src/?.lua;' .. package.path
require('onbox.support.fiber_runtime').configure(repo)

local total = 0
for _, module in ipairs({ 'auth_spec', 'runner_spec' }) do
    local tests = require('onbox.support.' .. module)
    local names = {}
    for name in pairs(tests) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        tests[name]()
        total = total + 1
        print('PASS ' .. module .. '.' .. name)
    end
end
print(('%d shared on-box support tests passed'):format(total))
