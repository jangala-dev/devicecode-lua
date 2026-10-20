#!/usr/bin/env luajit
-- Offline checks: no connection to a box and no password file access.
local posix = require 'posix'
local path = assert(posix.realpath(arg[0]))
local here = assert(path:match('^(.*)/[^/]+$'))
local repo = assert(here:match('^(.*)/tests/integration/onbox/modem_pdp$'))
package.path = repo .. '/tests/integration/?.lua;' .. repo .. '/src/?.lua;' .. package.path
local runner = require 'onbox.modem_pdp.runner'
local tablex = require 'shared.table'

---@param actual any
---@param expected any
---@return nil
local function equal(actual, expected)
    if type(expected) == 'table' then
        assert(type(actual) == 'table', 'Expected a table')
        for key, value in pairs(expected) do equal(actual[key], value) end
        for key in pairs(actual) do assert(expected[key] ~= nil, 'Unexpected key: ' .. tostring(key)) end
    else
        assert(actual == expected, ('Expected %s, got %s'):format(tostring(expected), tostring(actual)))
    end
end

---@param callback fun(): any
---@param message string
---@return nil
local function rejects(callback, message)
    local ok, err = pcall(callback)
    assert(not ok and tostring(err):find(message, 1, true), 'Expected failure containing: ' .. message)
end

local config = {
    net = { data = { preserve = 'network settings' } },
    gsm = { rev = 7, data = { modems = {
        default = { pdp_type = 'IP', autoconnect = true },
        known = {
            { imei = '123', pdp_type = 'IPV6', name = 'primary' },
            { id_field = 'device', device = '/sys/usb2', pdp_type = 'IPV4V6' },
        },
    } } },
}

local tests = {}

---@return nil
function tests.config_selection()
    equal(runner.effective_config(config, { imei = '123', device = '/sys/usb1' }).pdp_type, 'IPV6')
    equal(runner.effective_config(config, { imei = '456', device = '/sys/usb2' }).pdp_type, 'IPV4V6')
    equal(runner.effective_config(config, { imei = '789', device = '/sys/usb3' }).pdp_type, 'IP')
    local missing = tablex.deep_copy(config)
    missing.gsm.data.modems.default.pdp_type = nil
    equal(runner.effective_config(missing, { imei = '789', device = '/sys/usb3' }).pdp_type, 'IP')
end

---@return nil
function tests.phase_preserves_config()
    local before = tablex.deep_copy(config)
    local updated = runner.phase_config(config, 'IPV4V6')
    for _, modem in ipairs({ { imei = '123', device = '/sys/usb1' }, { imei = '456', device = '/sys/usb2' } }) do
        equal(runner.effective_config(updated, modem).pdp_type, 'IPV4V6')
    end
    equal(updated.net, before.net)
    equal(config, before)
    equal(updated.gsm.rev, 8)
    equal(updated.gsm.data.modems.default.autoconnect, true)
end

---@return nil
function tests.active_context_parser()
    equal(runner.check_contexts({
        ['AT+CGDCONT?'] = { '+CGDCONT: 2,"IPV6","ims",""', '+CGDCONT: 4, "IP", "a,b", ""' },
        ['AT+CGACT?'] = { '+CGACT: 4,1', '+CGACT: 2,0' },
    }, 'IP'), { { cid = 4, pdp_type = 'IP', apn = 'a,b' } })
    equal(runner.check_contexts({
        ['AT+CGDCONT?'] = { '+CGDCONT: 2,"IPV4V6","",""', '+CGDCONT: 1,"IPV4V6","internet",""' },
        ['AT+CGACT?'] = { '+CGACT: 2,1', '+CGACT: 1,1' },
    }, 'IPV4V6'), { { cid = 1, pdp_type = 'IPV4V6', apn = 'internet' },
        { cid = 2, pdp_type = 'IPV4V6', apn = '' } })
end

---@return nil
function tests.invalid_contexts_fail()
    for _, case in ipairs({
        { { '+CGDCONT: 1,"IP","",""' }, { '+CGACT: 1,1' }, 'expected IPV4V6' },
        { { '+CGDCONT: 1,"IPV4V6","",""' }, { '+CGACT: 2,1' }, 'Active CID missing' },
        { { '+CGDCONT: 1,"IPV4V6","",""' }, { '+CGACT: 1,0' }, 'No active contexts' },
        { {}, {}, 'No active contexts' },
        { { '+CGDCONT: 0,"IPV4V6","",""' }, {}, 'Malformed or duplicate CGDCONT' },
        { { '+CGDCONT: broken' }, {}, 'Malformed or duplicate CGDCONT' },
        { { '+CGDCONT: 1,"IPV4V6","",""', '+CGDCONT: 1,"IP","",""' }, {},
            'Malformed or duplicate CGDCONT' },
        { {}, { '+CGACT: 1,1', '+CGACT: 1,0' }, 'Malformed or duplicate CGACT' },
        { {}, { '+CGACT: 1,2' }, 'Malformed or duplicate CGACT' },
    }) do
        rejects(function()
            runner.check_contexts({ ['AT+CGDCONT?'] = case[1], ['AT+CGACT?'] = case[2] }, 'IPV4V6')
        end, case[3])
    end
end

---@return nil
function tests.arguments()
    local args = runner.parse_args({}, repo, here)
    equal(args.first, 'IP')
    equal(args.second, 'IPV4V6')
    equal(args.password_file, repo .. '/boxkey')
    equal(args.ask_pass, false)
    equal(args.build_command, 'make build-all')
    args = runner.parse_args({ '--ssh-key-auth', '--timeout', '42', '--keep-final-config',
        '--first', 'IPV6', '--second', 'IP', '--artifacts', 'my logs' }, repo, here)
    equal(args.password_file, nil)
    equal(args.timeout, 42)
    equal(args.keep_final_config, true)
    equal(args.artifacts, posix.getcwd() .. '/my logs')
    rejects(function() runner.parse_args({ '--first', 'IPV4V6' }, repo, here) end, 'Choose different')
    rejects(function() runner.parse_args({ '--timeout', '0' }, repo, here) end, 'Timeout must be positive')
    rejects(function() runner.parse_args({ '--runtime', '/' }, repo, here) end, 'Runtime must name')
    rejects(function() runner.parse_args({ '--host' }, repo, here) end, 'Missing value')
    args = runner.parse_args({ '--ask-pass' }, repo, here)
    equal(args.ask_pass, true)
    equal(args.password_file, nil)
    for _, flags in ipairs({ { '--ask-pass', '--ssh-key-auth' }, { '--ssh-key-auth', '--ask-pass' },
        { '--ask-pass', '--password-file', 'unused' }, { '--password-file', 'unused', '--ask-pass' } }) do
        rejects(function() runner.parse_args(flags, repo, here) end, 'Choose one of')
    end
end

local names = {}
for name in pairs(tests) do names[#names + 1] = name end
table.sort(names)
for _, name in ipairs(names) do
    tests[name]()
    print('PASS ' .. name)
end
print(('%d offline runner tests passed'):format(#names))
