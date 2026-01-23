-- Detect if this file is being run as the entry point
local this_file = debug.getinfo(1, "S").source:match("@?([^/]+)$")
local is_entry_point = arg and arg[0] and arg[0]:match("[^/]+$") == this_file

if is_entry_point then
    -- Match the test harness package.path setup (see tests/test.lua,
    -- test_wifi.lua, test_metrics.lua, test_system.lua, test_core.lua)
    package.path = "../../src/lua-fibers/?.lua;" -- fibers submodule src
        .. "../../src/lua-trie/src/?.lua;"       -- trie submodule src
        .. "../../src/lua-bus/src/?.lua;"        -- bus submodule src
        .. "../../src/?.lua;"                    -- main src tree
        .. "../../?.lua;"                        -- repo root (for tests.hal.harness)
        .. "./test_utils/?.lua;"                 -- shared test utilities
        .. package.path
        .. ";/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua;"
        .. "./harness/?.lua;"

    _G._TEST = true -- Enable test exports in source code
    local log = require 'services.log'
    local rxilog = require 'rxilog'
    for _, mode in ipairs(rxilog.modes) do
        log[mode.name] = function() end -- no-op logging during tests, comment out to see logs
    end
end

local luaunit = require 'luaunit'
local fiber = require 'fibers.fiber'
local context = require 'fibers.context'
local sleep = require 'fibers.sleep'
local channel = require 'fibers.channel'

local harness = require 'tests.hal.harness'
local mock = require 'tests.utils.mock'
local commands = require 'tests.utils.ShimCommands'

local function make_monitor_event(is_added, address)
    local sign = is_added and '(+)' or '(-)'
    return string.format("%s %s [DUMMY MANAFACUTER] Dummy Modem Module", sign,
        address)
end

local function release(module_path)
    package.loaded[module_path] = nil
end

TestHalModemcardManager = {}

function TestHalModemcardManager:test_detector()
    local ctx = context.with_cancel(context.background())

    -- Setup mmcli backend command mocks
    local mmcli = require 'tests.hal.harness.backends.mmcli'
    local mmcli_mock = mock.new_module(
        "services.hal.drivers.modem.mmcli",
        mmcli
    )
    mmcli_mock:apply()

    local monitor_modems_cmd = commands.new_command(ctx)
    mmcli.set_command("monitor_modems", monitor_modems_cmd)

    local modem_manager_module = require 'services.hal.managers.modemcard'
    local modem_manager = modem_manager_module.new()
    local modem_detect_ch = modem_manager.modem_detect_channel
    local modem_remove_ch = modem_manager.modem_remove_channel
    fiber.spawn(function()
        modem_manager:_detector(ctx)
    end)

    local address = "/org/freedesktop/ModemManager1/Modem/0"

    -- Simulate modem addition
    monitor_modems_cmd.stdout_ch:put(make_monitor_event(true, address))
    local detected_address, err = harness.wait_for_channel(modem_detect_ch, ctx)
    luaunit.assertNil(err)
    luaunit.assertEquals(detected_address, address)


    -- Simulate modem removal
    monitor_modems_cmd.stdout_ch:put(make_monitor_event(false, address))
    local removed_address, err = harness.wait_for_channel(modem_remove_ch, ctx)
    luaunit.assertNil(err)
    luaunit.assertEquals(removed_address, address)

    -- Simulate no modems
    monitor_modems_cmd.stdout_ch:put("No modems found")
    local no_event, err = harness.wait_for_channel(modem_detect_ch, ctx)
    luaunit.assertNil(no_event)
    luaunit.assertEquals(err, 'timeout')

    -- Verify command call counts
    luaunit.assertEquals(monitor_modems_cmd.calls.start, 1)

    ctx:cancel('test complete')
    -- Cleanup modules from cache
    mmcli_mock:clear()
    release "services.hal.managers.modemcard"
    sleep.sleep(0) -- allow fiber to exit

    luaunit.assertEquals(monitor_modems_cmd.calls.wait, 1)
    luaunit.assertEquals(monitor_modems_cmd.calls.kill, 1)
    luaunit.assertEquals(monitor_modems_cmd.calls.close, 1)
end

function TestHalModemcardManager:test_manager()
    local ctx = context.with_cancel(context.background())

    -- Setup modem driver mock (this will be a driver instance)
    local modem_mock = mock.new_object {
        init = { nil },
        apply_capabilities = { {}, nil },
        spawn = {}
    }

    local modem_inst = modem_mock:create_instance()

    -- Setup modem driver module mock (to return the driver instance)
    local modem_driver_module_mock = mock.new_module(
        "services.hal.drivers.modem",
        {
            -- a mock can take a function for dynamic behavior or table of return values for static behavior
            new = function(mctx, address)
                modem_inst.address = address
                modem_inst.device = "dummy"
                modem_inst.ctx = mctx
                return modem_inst
            end
        }
    )
    modem_driver_module_mock:apply()

    -- Setup mmcli backend command mocks
    local mmcli = require 'tests.hal.harness.backends.mmcli'
    local mmcli_mock = mock.new_module(
        "services.hal.drivers.modem.mmcli",
        mmcli
    )
    mmcli_mock:apply()

    local modem_manager_module = require 'services.hal.managers.modemcard'
    local modem_manager = modem_manager_module.new()
    local modem_detect_ch = modem_manager.modem_detect_channel
    local modem_remove_ch = modem_manager.modem_remove_channel
    local device_event_q = channel.new()
    local capability_info_q = channel.new()
    fiber.spawn(function()
        modem_manager:_manager(
            ctx,
            nil,
            device_event_q,
            capability_info_q
        )
    end)
    local address = "/org/freedesktop/ModemManager1/Modem/0"

    -- Simulate modem detection
    modem_detect_ch:put(address)
    local device_event, err = harness.wait_for_channel(device_event_q, ctx)
    luaunit.assertNil(err)
    luaunit.assertEquals(device_event.connected, true)
    luaunit.assertEquals(device_event.data.port, "dummy")
    luaunit.assertEquals(modem_inst._calls.init, 1)
    luaunit.assertEquals(modem_inst._calls.apply_capabilities, 1)
    luaunit.assertEquals(modem_inst._calls.spawn, 1)

    -- Simulate modem removal
    modem_remove_ch:put(address)
    local device_event, err = harness.wait_for_channel(device_event_q, ctx)
    luaunit.assertNil(err)
    luaunit.assertEquals(device_event.connected, false)
    luaunit.assertEquals(device_event.data.port, "dummy")

    ctx:cancel('test complete')
    -- Cleanup modules from cache
    modem_driver_module_mock:clear()
    mmcli_mock:clear()
    release "services.hal.managers.modemcard"
    sleep.sleep(0) -- allow fiber to exit
end

local function main()
    fiber.spawn(function()
        luaunit.LuaUnit.run()
        fiber.stop()
    end)
end

-- Only run tests if this file is executed directly (not via dofile)
if is_entry_point then
    main()
    fiber.main()
end
