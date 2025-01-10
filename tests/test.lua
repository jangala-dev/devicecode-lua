package.path = "../src/lua-fibers/?.lua;" -- fibers submodule src
    .. "../src/lua-trie/src/?.lua;"       -- trie submodule src
    .. "../src/lua-bus/src/?.lua;"        -- bus submodule src
    .. "../src/?.lua;"
    .. package.path
    .. ";/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua"

local base_pkg_path = package.path

local tests = {
    "submodules",
    "service",
    "hal_utils",
    "modem_driver",
}

for _, test in ipairs(tests) do
    dofile("test_" .. test .. ".lua")
    package.path = base_pkg_path
end
