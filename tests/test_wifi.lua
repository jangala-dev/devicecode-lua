-- Detect if this file is being run as the entry point
local this_file = debug.getinfo(1, "S").source:match("@?([^/]+)$")
local is_entry_point = arg and arg[0] and arg[0]:match("[^/]+$") == this_file

if is_entry_point then
    package.path = "../src/lua-fibers/?.lua;" -- fibers submodule src
        .. "../src/lua-trie/src/?.lua;"       -- trie submodule src
        .. "../src/lua-bus/src/?.lua;"        -- bus submodule src
        .. "../src/?.lua;"
        .. "./test_utils/?.lua;"
        .. package.path
        .. ";/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua"

    _G._TEST = true -- Enable test exports in source code
end

local luaunit = require 'luaunit'
local fiber = require "fibers.fiber"
local context = require "fibers.context"
local sleep = require "fibers.sleep"

TestWifiClientEvents = {}

local function setup_wifi_test_environment()
    local bus_pkg = require "bus"
    local bus = bus_pkg.new()
    luaunit.assertNotNil(bus)

    local wifi_service = require "services.wifi"
    luaunit.assertNotNil(wifi_service.wifi_service)
    luaunit.assertNotNil(wifi_service.new_radio)

    return wifi_service, bus, bus_pkg.new_msg
end

function TestWifiClientEvents:test_normal_client_connection()
    local wifi, bus, new_msg = setup_wifi_test_environment()
    local conn = bus:connect()
    local bg_ctx = context.background()
    local ctx, cancel = context.with_cancel(bg_ctx)

    local radio_index = "radio0"
    local ssid = "ssid_name"
    local interface = "wlan0"
    local radio = wifi.new_radio(ctx, bus:connect(), radio_index)
    radio.band_ch:put("2g") -- Radio will not listen for clients unless band is set
    -- We need to link the interface to an index
    radio.interface_ch:put({ name = ssid, index = 1 }) -- First link ssid to index
    conn:publish(new_msg( -- Then link  interface to ssid
        {
        'hal',
        'capability',
        'wireless',
        radio_index,
        'info',
        'interface',
        interface,
        'ssid'
        },
        ssid
    ))
    fiber.yield()

    local client_mac = "AA:BB:CC:DD:EE:FF"
    local timestamp = 123456789
    conn:publish(new_msg(
        { 'hal', 'capability', 'wireless', radio_index, 'info', 'interface', interface, 'client', client_mac },
        {
            connected = true,
            timestamp = timestamp
        }
    ))
    local session_sub = conn:subscribe({ 'wifi', 'clients', '+', 'sessions', '+', 'session_start'})

    local session_msg, err = session_sub:next_msg_with_context(context.with_timeout(ctx, 0.1))
    luaunit.assertNil(err)

    local session_timestamp = session_msg.payload or nil
    luaunit.assertNotNil(session_timestamp)
    luaunit.assertEquals(session_timestamp, timestamp) -- Check timestamp matches
end

function TestWifiClientEvents:test_duplicate_connection_event()
    -- Test a double client event (same MAC) disregards the second event and does not make a new session
end

function TestWifiClientEvents:test_normal_disconnection_event()
    -- Test a normal disconnection event
end

function TestWifiClientEvents:test_duplicate_disconnection_event()
    -- Test a double disconnection event (same MAC) disregards the second event and does not try to close a non-existent session
end

-- Only run tests if this file is executed directly (not via dofile)
if is_entry_point then
    fiber.spawn(function()
        luaunit.LuaUnit.run()
        fiber.stop()
    end)

    fiber.main()
end
