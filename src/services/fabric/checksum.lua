-- services/fabric/checksum.lua
--
-- Small, dependency-free checksum helpers.
--
-- This is intentionally simple; it provides a deterministic integrity checksum
-- for transfer protocol use and tests without pulling in a crypto dependency.
-- It is not a security primitive.

local M = {}

local MOD = 65521

local function adler32_bytes_iter(bytes)
	local a, b = 1, 0
	for i = 1, #bytes do
		a = (a + bytes:byte(i)) % MOD
		b = (b + a) % MOD
	end
	return a, b
end

local function hex8(n)
	return ('%08x'):format(n)
end

function M.adler32(s)
	assert(type(s) == 'string', 'checksum.adler32 expects string')
	local a, b = adler32_bytes_iter(s)
	return b * 65536 + a
end

function M.digest_hex(s)
	return hex8(M.adler32(s))
end

function M.verify_hex(s, expected)
	return M.digest_hex(s) == tostring(expected)
end

return M
