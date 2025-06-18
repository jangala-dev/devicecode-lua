package.path = "../src/lua-fibers/?.lua;"
    .. "../src/lua-trie/src/?.lua;"
    .. "../src/lua-bus/src/?.lua;"
    .. "../src/?.lua;"
    .. package.path
    .. ";/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua"

print("starting submodule tests")

assert(require 'fibers.fiber')
assert(require 'trie')
assert(require 'uuid')
assert(require 'bus')

print("tests complete")
