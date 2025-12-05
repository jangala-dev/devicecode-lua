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

local function ssid_path(radio_index, interface)
    return { 'hal', 'capability', 'wireless', radio_index, 'info', 'interface', interface, 'ssid' }
end

local function client_event_path(radio_index, interface, client_mac)
    return { 'hal', 'capability', 'wireless', radio_index, 'info', 'interface', interface, 'client', client_mac }
end

local function session_start_path()
    return { 'wifi', 'clients', '+', 'sessions', '+', 'session_start' }
end

local function session_end_path()
    return { 'wifi', 'clients', '+', 'sessions', '+', 'session_end' }
end

function TestWifiClientEvents:test_normal_client_connection()
    -- Setup test environment
    local wifi, bus, new_msg = setup_wifi_test_environment()
    local conn = bus:connect()
    local ctx = context.with_cancel(context.background())

    -- Configure radio and interface
    local radio_index = "radio0"
    local interface = "wlan0"
    local ssid = "test_ssid"

    local radio = wifi.new_radio(ctx, bus:connect(), radio_index)
    radio.band_ch:put("2g")
    radio.interface_ch:put({ name = ssid, index = 1 })
    conn:publish(new_msg(ssid_path(radio_index, interface), ssid))
    fiber.yield()

    -- Subscribe before publishing the connection event
    local session_sub = conn:subscribe(session_start_path())

    -- Publish client connection event
    local client_mac = "AA:BB:CC:DD:EE:FF"
    local timestamp = 123456789
    conn:publish(new_msg(
        client_event_path(radio_index, interface, client_mac),
        { connected = true, timestamp = timestamp }
    ))

    -- Verify session_start message was published with correct timestamp
    local session_msg, err = session_sub:next_msg_with_context(context.with_timeout(ctx, 0.1))
    luaunit.assertNil(err, "Expected session_start message")
    luaunit.assertNotNil(session_msg.payload)
    luaunit.assertEquals(session_msg.payload, timestamp)
end

function TestWifiClientEvents:test_duplicate_connection_event()
    -- Setup test environment
    local wifi, bus, new_msg = setup_wifi_test_environment()
    local conn = bus:connect()
    local ctx = context.with_cancel(context.background())

    -- Configure radio and interface
    local radio_index = "radio0"
    local interface = "wlan0"
    local ssid = "test_ssid"

    local radio = wifi.new_radio(ctx, bus:connect(), radio_index)
    radio.band_ch:put("2g")
    radio.interface_ch:put({ name = ssid, index = 1 })
    conn:publish(new_msg(ssid_path(radio_index, interface), ssid))
    fiber.yield()

    local session_sub = conn:subscribe(session_start_path())
    local client_mac = "AA:BB:CC:DD:EE:FF"

    -- Publish first connection event
    conn:publish(new_msg(
        client_event_path(radio_index, interface, client_mac),
        { connected = true, timestamp = 1 }
    ))

    -- Publish duplicate connection event (same MAC, still connected)
    conn:publish(new_msg(
        client_event_path(radio_index, interface, client_mac),
        { connected = true, timestamp = 2 }
    ))

    -- Verify first connection event created a session
    local session_msg, err = session_sub:next_msg_with_context(context.with_timeout(ctx, 0.1))
    luaunit.assertNil(err, "Expected first session_start message")
    luaunit.assertEquals(session_msg.payload, 1)

    -- Verify duplicate connection event was ignored (no second session_start)
    local session_msg2, err2 = session_sub:next_msg_with_context(context.with_timeout(ctx, 0.1))
    luaunit.assertNotNil(err2, "Expected timeout - duplicate should be ignored")
    luaunit.assertNil(session_msg2)
end

function TestWifiClientEvents:test_normal_disconnection_event()
    -- Setup test environment
    local wifi, bus, new_msg = setup_wifi_test_environment()
    local conn = bus:connect()
    local ctx = context.with_cancel(context.background())

    -- Configure radio and interface
    local radio_index = "radio0"
    local interface = "wlan0"
    local ssid = "test_ssid"

    local radio = wifi.new_radio(ctx, bus:connect(), radio_index)
    radio.band_ch:put("2g")
    radio.interface_ch:put({ name = ssid, index = 1 })
    conn:publish(new_msg(ssid_path(radio_index, interface), ssid))
    fiber.yield()

    local client_mac = "AA:BB:CC:DD:EE:FF"
    local connect_time = 100
    local disconnect_time = 200

    -- Connect the client
    conn:publish(new_msg(
        client_event_path(radio_index, interface, client_mac),
        { connected = true, timestamp = connect_time }
    ))
    fiber.yield()

    -- Subscribe before disconnecting
    local session_sub = conn:subscribe(session_end_path())

    -- Disconnect the client
    conn:publish(new_msg(
        client_event_path(radio_index, interface, client_mac),
        { connected = false, timestamp = disconnect_time }
    ))

    -- Verify session_end message was published with correct timestamp
    local session_msg, err = session_sub:next_msg_with_context(context.with_timeout(ctx, 0.1))
    luaunit.assertNil(err, "Expected session_end message")
    luaunit.assertNotNil(session_msg.payload)
    luaunit.assertEquals(session_msg.payload, disconnect_time)
end

function TestWifiClientEvents:test_duplicate_disconnection_event()
    local wifi, bus, new_msg = setup_wifi_test_environment()
    local conn = bus:connect()
    local bg_ctx = context.background()
    local ctx, cancel = context.with_cancel(bg_ctx)

    -- Setup: Create radio and interface
    local radio_index = "radio0"
    local interface = "wlan0"
    local ssid = "ssid_name"

    local radio = wifi.new_radio(ctx, bus:connect(), radio_index)
    radio.band_ch:put("2g")
    radio.interface_ch:put({ name = ssid, index = 1 })
    conn:publish(new_msg(ssid_path(radio_index, interface), ssid))
    fiber.yield()

    local client_mac = "AA:BB:CC:DD:EE:FF"
    local connect_time = 100
    local disconnect_time = 200

    -- Connect the client first
    conn:publish(new_msg(
        client_event_path(radio_index, interface, client_mac),
        { connected = true, timestamp = connect_time }
    ))
    fiber.yield()

    local session_sub = conn:subscribe(session_end_path())

    -- Action: Publish first disconnection event
    conn:publish(new_msg(
        client_event_path(radio_index, interface, client_mac),
        { connected = false, timestamp = disconnect_time }
    ))

    -- Action: Publish duplicate disconnection event (should be ignored)
    conn:publish(new_msg(
        client_event_path(radio_index, interface, client_mac),
        { connected = false, timestamp = disconnect_time + 1 }
    ))

    -- Verify: First disconnection created a session_end message
    local session_msg, err = session_sub:next_msg_with_context(context.with_timeout(ctx, 0.1))
    luaunit.assertNil(err, "Expected first session_end message")
    luaunit.assertEquals(session_msg.payload, disconnect_time, "Session end timestamp should match first disconnect")

    -- Verify: Duplicate disconnection was ignored (no second session_end)
    local session_msg2, err2 = session_sub:next_msg_with_context(context.with_timeout(ctx, 0.1))
    luaunit.assertNotNil(err2, "Expected timeout - duplicate disconnect should be ignored")
    luaunit.assertNil(session_msg2, "No second session_end should be published")
end

-- Only run tests if this file is executed directly (not via dofile)
if is_entry_point then
    fiber.spawn(function()
        luaunit.LuaUnit.run()
        fiber.stop()
    end)

    fiber.main()
end
