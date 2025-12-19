-- Standalone demo test: bring up a dummy modem with no SIM,
-- wait a bit, then insert a SIM and wait again so we can
-- observe modem logs on the console.

local this_file = debug.getinfo(1, "S").source:match("@?([^/]+)$")
local is_entry_point = arg and arg[0] and arg[0]:match("[^/]+$") == this_file

if is_entry_point then
    package.path = "../../src/lua-fibers/?.lua;" -- fibers submodule src
        .. "../../src/lua-trie/src/?.lua;"       -- trie submodule src
        .. "../../src/lua-bus/src/?.lua;"        -- bus submodule src
        .. "../../src/?.lua;"                    -- main src tree
        .. "../../?.lua;"                        -- repo root (for tests.hal.harness)
        .. "./test_utils/?.lua;"                 -- shared test utilities
        .. package.path
        .. ";/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua;"
        .. "./harness/?.lua;"

    _G._TEST = true
end

local luaunit = require 'luaunit'
local fiber = require 'fibers.fiber'
local context = require 'fibers.context'
local sleep = require 'fibers.sleep'

local harness = require 'tests.hal.harness'
local dummy_modem = require 'tests.hal.harness.devices.modem'

TestHalModemDriver = {}
TestHalModemSimInsert = {}

-- function TestHalModemDriver:test_modem_enable()
--     local hal, ctx, bus, conn, new_msg = harness.new_hal_env()

--     hal:start(ctx, bus:connect())

--     local config = {
--         managers = {
--             modemcard = {},
--         },
--     }
--     harness.publish_config(conn, new_msg, config)

--     local modem = dummy_modem.new(context.with_cancel(ctx), 'failed')
--     modem:set_address_index("0")
--     modem:set_mmcli_information{
--         modem = {
--             generic = {
--                 device = "/fake/port0",
--                 ["equipment-identifier"] = "123456789",
--             }
--         }
--     }
-- end

function TestHalModemSimInsert:test_modem_sim_insert_logs()
    -- Bring up a fresh HAL environment with the modemcard manager
    -- running under HAL so we can call capability control endpoints
    -- like sim_detect.
    local hal, ctx, bus, conn, new_msg = harness.new_hal_env()

    -- Start HAL control loop.
    hal:start(ctx, bus:connect())

    -- Enable only the modemcard manager via HAL config.
    local config = {
        managers = {
            modemcard = {},
        },
    }
    harness.publish_config(conn, new_msg, config)

    -- Create a dummy modem with no SIM present.
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

    -- Make the modem appear on the bus so the manager and driver
    -- start up and begin logging.
    local wr_err = modem:appear()
    luaunit.assertNil(wr_err, "Failed to write to monitor command stdout")

    -- Wait a bit with no SIM inserted so we can see the initial
    -- modem logs and then trigger SIM detection via the HAL
    -- capability control endpoint.
    sleep.sleep(1)

    -- Call the modem sim_detect endpoint so the driver starts
    -- its SIM detection / warm-swap logic. The modem capability
    -- id is the IMEI we set above (123456789).
    local bus_pkg = require 'bus'
    local new_msg_fn = bus_pkg.new_msg or new_msg
    local sim_detect_sub = conn:request(new_msg_fn(
        { 'hal', 'capability', 'modem', '123456789', 'control', 'sim_detect' },
        {}
    ))
    -- We don't assert on the response; this is just to ensure the
    -- request is consumed and does not block.
    local _ = sim_detect_sub:next_msg_with_context_op(context.with_timeout(ctx, 5)):perform()
    sleep.sleep(5)

    -- Now insert a SIM and wait again to observe the resulting
    -- modem state changes and logs.
    local sim = dummy_modem.new_sim()
    sim:set_imsi("001010123456789")
    sim:set_operator("00101", "Test Operator")
    modem:insert_sim(sim)

    sleep.sleep(2)

    -- Cleanly shut down the environment.
    ctx:cancel('test complete')
    sleep.sleep(0)
end

local function main()
    fiber.spawn(function()
        luaunit.LuaUnit.run()
        fiber.stop()
    end)
end

if is_entry_point then
    main()
    fiber.main()
end
