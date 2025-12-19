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
    -- for _, mode in ipairs(rxilog.modes) do
    --     log[mode.name] = function() end -- no-op logging during tests
    -- end
end

local luaunit = require 'luaunit'
local fiber = require 'fibers.fiber'
local channel = require 'fibers.channel'
local context = require 'fibers.context'
local sleep = require 'fibers.sleep'

local harness = require 'tests.hal.harness'
local templates = require 'tests.hal.templates'
local dummy_modem = require 'tests.hal.harness.devices.modem'

TestHalModemcardManager = {}

function TestHalModemcardManager:test_modem_monitor_events()
    local _, ctx, bus, conn, new_msg = harness.new_hal_env()
    local manager = require 'services.hal.managers.modemcard'.new()
    local device_event_q = channel.new()
    local capability_info_q = channel.new()
    manager:spawn(context.with_cancel(ctx), bus:connect(), device_event_q, capability_info_q)

    -- 1. No modems present
    local nomodem = dummy_modem.no_modem()
    local wr_err = nomodem:appear()
    luaunit.assertNil(wr_err, "Failed to write to monitor command stdout")

    local result, err = harness.wait_for_channel(device_event_q, ctx, 20) -- wait for no add event
    luaunit.assertNil(result, "Did not expect a device event")
    luaunit.assertEquals(err, 'timeout')

    -- pre 2&3. Create dummy modem
    local modem = dummy_modem.new(context.with_cancel(ctx))
    modem:set_address_index("0")
    modem:set_mmcli_information{
        modem = {
            generic = {
                device = "/fake/port0",
                ["equipment-identifier"] = "123456789",
            }
        }
    }

    -- 2. Modem 0 added
    wr_err = modem:appear()
    luaunit.assertNil(wr_err, "Failed to write to monitor command stdout")


    result, err = harness.wait_for_channel(device_event_q, ctx, 20) -- wait for add event
    -- ignore control object
    if result.capabilities.modem then result.capabilities.modem.control = "" end
    -- build expected event
    local expected_event = templates.make_modem_device_event{
        connected = true,
        data = {
            port = "/fake/port0"
        },
        capabilities = {
            modem = {
                id = "123456789",
                control = "" -- we don't care about the control object here
            }
        }
    }
    luaunit.assertNotNil(result, "Expected a device event")
    luaunit.assertEquals(err, nil)
    luaunit.assertEquals(result, expected_event)

    -- 3. Modem 0 removed
    wr_err = modem:disappear()
    luaunit.assertNil(wr_err, "Failed to write to monitor command stdout")
    result, err = harness.wait_for_channel(device_event_q, ctx, 20) -- wait for remove event
    -- expected_event = make_expected_device_event(false, make_full_address("0"))
    expected_event = templates.make_modem_device_event{
        connected = false,
        data = {
            port = "/fake/port0"
        }
    }
    luaunit.assertNotNil(result, "Expected a device event")
    luaunit.assertEquals(err, nil)
    luaunit.assertEquals(result, expected_event)

    ctx:cancel('test complete')
    sleep.sleep(0) -- allow manager to exit
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
