package.path = "../src/lua-fibers/?.lua;" -- fibers submodule src
    .. "../src/lua-trie/src/?.lua;"       -- trie submodule src
    .. "../src/lua-bus/src/?.lua;"        -- bus submodule src
    .. "../src/?.lua;"
    .. package.path
    .. ";/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua"

local tests = {
    "service",
    "submodules"
}

for _, test in ipairs(tests) do
    dofile("test_" .. test .. ".lua")
end
