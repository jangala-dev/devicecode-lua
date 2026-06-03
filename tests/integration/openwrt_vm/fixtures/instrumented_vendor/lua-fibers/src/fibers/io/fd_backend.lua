-- fibers/io/fd_backend.lua
--
-- FD-backed backend shim.
-- Chooses the best available implementation:
--   1. FFI-based (no luaposix dependency),
--   2. luaposix-based (no FFI dependency).
--
---@module 'fibers.io.fd_backend'

local candidates = {
	'fibers.io.fd_backend.ffi', -- FFI / libc
	'fibers.io.fd_backend.posix', -- luaposix
	'fibers.io.fd_backend.nixio', -- nixio
}

for _, name in ipairs(candidates) do
	local ok, mod = pcall(require, name)
	if ok and type(mod) == 'table' and mod.is_supported and mod.is_supported() then
		return mod
	end
end

error('fibers.io.fd_backend: no suitable fd backend available on this platform')
