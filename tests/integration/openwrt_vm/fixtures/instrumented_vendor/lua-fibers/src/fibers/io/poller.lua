-- fibers/io/poller.lua
--
-- Poller shim: chooses the best available backend.
-- Order matters: we prefer epoll (FFI) when possible, then fall back
-- to a pure-luaposix select/poll implementation.

local candidates = {
	'fibers.io.poller.epoll', -- Linux + FFI/epoll
	'fibers.io.poller.select', -- luaposix poll/select
	'fibers.io.poller.nixio', -- nixio poll/select
}

for _, name in ipairs(candidates) do
	local ok, mod = pcall(require, name)
	if ok and type(mod) == 'table' and mod.is_supported and mod.is_supported() then
		return mod
	end
end

error('fibers.io.poller: no suitable poller backend available on this platform')
