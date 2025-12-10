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
local system = require 'services.system'

local build_table = system.build_table
local merge_tables = system.merge_tables

TestSystemMetrics = {}

function TestSystemMetrics:test_metric_shapes_and_nesting()
    local stats = {}

    -- 1) Single-key, scalar value (e.g. temperature)
    merge_tables(stats, build_table({ 'temperature' }, 42))
    luaunit.assertEquals(stats.temperature, 42)

    -- 2) Multi-key, scalar value (e.g. hardware.revision)
    merge_tables(stats, build_table({ 'hardware', 'revision' }, 'rev1'))
    luaunit.assertNotNil(stats.hardware)
    luaunit.assertEquals(stats.hardware.revision, 'rev1')

    -- 3) Single-key, table value (e.g. cpu utilisation struct)
    local cpu_value = {
        overall_utilisation = 12.5,
        core_utilisations = { cpu0 = 34.0 },
    }
    merge_tables(stats, build_table({ 'cpu' }, cpu_value))

    -- Ensure CPU table is nested under 'cpu', not flattened
    luaunit.assertNotNil(stats.cpu)
    luaunit.assertEquals(stats.cpu.overall_utilisation, 12.5)
    luaunit.assertEquals(stats.cpu.core_utilisations.cpu0, 34.0)
    luaunit.assertNil(stats.overall_utilisation)

    -- 4) Multi-key, table value (generic nested case)
    local mem_extra = { foo = 1, bar = 2 }
    merge_tables(stats, build_table({ 'mem', 'extra' }, mem_extra))

    luaunit.assertNotNil(stats.mem)
    luaunit.assertNotNil(stats.mem.extra)
    luaunit.assertEquals(stats.mem.extra.foo, 1)
    luaunit.assertEquals(stats.mem.extra.bar, 2)
end

-- Only run tests if this file is executed directly (not via dofile)
if is_entry_point then
    local fiber = require 'fibers.fiber'
    fiber.spawn(function()
        luaunit.LuaUnit.run()
        fiber.stop()
    end)
    fiber.main()
end
