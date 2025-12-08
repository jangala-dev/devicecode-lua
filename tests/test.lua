package.path = "../src/lua-fibers/?.lua;" -- fibers submodule src
    .. "../src/lua-trie/src/?.lua;"       -- trie submodule src
    .. "../src/lua-bus/src/?.lua;"        -- bus submodule src
    .. "../src/?.lua;"
    .. "./test_utils/?.lua;"
    .. package.path
    .. ";/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua"

local base_pkg_path = package.path

_G._TEST = true -- global test flag

local tests = {
    "submodules",
    "service",
    "hal_utils",
    -- "modem_driver",
    -- "modemcard_manager",
    -- "hal_capabilities",
    -- "hal",
    "metrics",
    "wifi"
}

for _, test in ipairs(tests) do
    dofile("test_" .. test .. ".lua")
    package.path = base_pkg_path
    -- package.loaded = nil
end

-- Run all accumulated tests
local fiber = require "fibers.fiber"
local luaunit = require "luaunit"

fiber.spawn(function()
    luaunit.LuaUnit.run()
    fiber.stop()
end)

fiber.main()
