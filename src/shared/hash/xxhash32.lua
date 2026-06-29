-- shared/hash/xxhash32.lua
--
-- Portable xxHash32, seed 0 by default.
--
-- This implementation does not use bit.band(x, 0xffffffff) or
-- bit32.band(x, 0xffffffff) as a 32-bit normalisation primitive. Some bit32
-- compatibility modules under LuaJIT/OpenWrt mishandle large Lua numeric
-- intermediates in that pattern. Unsigned 32-bit normalisation is therefore
-- done with arithmetic modulo 2^32, while bit libraries are used only for
-- true bitwise operations on already-normalised values.

local ok_bit, bit_mod = pcall(require, 'bit')
local ok_bit32, bit32_mod = pcall(require, 'bit32')

local raw_bitops = ok_bit and bit_mod or (ok_bit32 and bit32_mod or nil)
assert(raw_bitops, 'shared.hash.xxhash32 requires bit or bit32')

local TWO32 = 4294967296
local TWO16 = 65536

local function u32(n)
	-- Lua numbers are doubles in LuaJIT/Lua 5.1. All intermediates in this
	-- implementation are kept well below 2^53, so modulo is exact here.
	n = n % TWO32
	if n < 0 then n = n + TWO32 end
	return n
end

local function band(a, b)
	return u32(raw_bitops.band(u32(a), u32(b)))
end

local function bor(a, b)
	return u32(raw_bitops.bor(u32(a), u32(b)))
end

local function bxor(a, b)
	return u32(raw_bitops.bxor(u32(a), u32(b)))
end

local function lshift(a, n)
	n = n % 32
	return u32(raw_bitops.lshift(u32(a), n))
end

local function rshift(a, n)
	n = n % 32
	return u32(raw_bitops.rshift(u32(a), n))
end

local function rol(a, n)
	n = n % 32
	a = u32(a)
	if n == 0 then return a end
	return bor(lshift(a, n), rshift(a, 32 - n))
end

local M = {}
M._backend = ok_bit and 'bit' or 'bit32'

local P1 = 0x9E3779B1
local P2 = 0x85EBCA77
local P3 = 0xC2B2AE3D
local P4 = 0x27D4EB2F
local P5 = 0x165667B1

local function hex8(n)
	-- Avoid string.format('%x', n): on some plain Lua runtimes n is a float,
	-- even when it represents an exact unsigned 32-bit integer.
	n = u32(n)
	local digits = '0123456789abcdef'
	local out = {}
	for shift = 28, 0, -4 do
		local nibble = math.floor(n / (2 ^ shift)) % 16
		out[#out + 1] = digits:sub(nibble + 1, nibble + 1)
	end
	return table.concat(out)
end

local function mul32(a, b)
	-- Exact low 32 bits of a 32x32 multiply using 16-bit limbs.
	-- This avoids relying on Lua's double precision for the full product and
	-- avoids passing a >32-bit intermediate into the bit backend.
	a = u32(a)
	b = u32(b)

	local a_lo = a % TWO16
	local a_hi = math.floor(a / TWO16)
	local b_lo = b % TWO16
	local b_hi = math.floor(b / TWO16)

	local lo = a_lo * b_lo
	local mid = a_hi * b_lo + a_lo * b_hi
	return u32((lo % TWO32) + ((mid % TWO16) * TWO16))
end

local function read_u32_le(s, i)
	local b1, b2, b3, b4 = s:byte(i, i + 3)
	return u32(
		(b1 or 0) +
		(b2 or 0) * 0x100 +
		(b3 or 0) * 0x10000 +
		(b4 or 0) * 0x1000000
	)
end

local function round_lane(acc, lane)
	acc = u32(acc + mul32(lane, P2))
	acc = rol(acc, 13)
	acc = mul32(acc, P1)
	return acc
end

local function avalanche(h)
	h = bxor(h, rshift(h, 15))
	h = mul32(h, P2)
	h = bxor(h, rshift(h, 13))
	h = mul32(h, P3)
	h = bxor(h, rshift(h, 16))
	return u32(h)
end

function M.new(seed)
	seed = u32(seed or 0)
	return {
		seed = seed,
		total_len = 0,
		mem = '',
		v1 = u32(seed + P1 + P2),
		v2 = u32(seed + P2),
		v3 = seed,
		v4 = u32(seed - P1),
		large = false,
	}
end

function M.update(state, s)
	assert(type(state) == 'table', 'checksum.update expects state')
	assert(type(s) == 'string', 'checksum.update expects string')
	if s == '' then return state end

	state.total_len = state.total_len + #s
	local buf = state.mem .. s
	local idx = 1
	local n = #buf

	if n >= 16 then
		state.large = true
		while idx + 15 <= n do
			state.v1 = round_lane(state.v1, read_u32_le(buf, idx)); idx = idx + 4
			state.v2 = round_lane(state.v2, read_u32_le(buf, idx)); idx = idx + 4
			state.v3 = round_lane(state.v3, read_u32_le(buf, idx)); idx = idx + 4
			state.v4 = round_lane(state.v4, read_u32_le(buf, idx)); idx = idx + 4
		end
	end

	state.mem = buf:sub(idx)
	return state
end

function M.digest(state)
	assert(type(state) == 'table', 'checksum.digest expects state')

	local h
	if state.large then
		h = u32(
			rol(state.v1, 1) +
			rol(state.v2, 7) +
			rol(state.v3, 12) +
			rol(state.v4, 18)
		)
	else
		h = u32(state.seed + P5)
	end

	h = u32(h + state.total_len)

	local i = 1
	local n = #state.mem

	while i + 3 <= n do
		h = u32(h + mul32(read_u32_le(state.mem, i), P3))
		h = mul32(rol(h, 17), P4)
		i = i + 4
	end

	while i <= n do
		h = u32(h + mul32(state.mem:byte(i) or 0, P5))
		h = mul32(rol(h, 11), P1)
		i = i + 1
	end

	return avalanche(h)
end

function M.digest_hex_state(state)
	return hex8(M.digest(state))
end

function M.xxhash32(s, seed)
	assert(type(s) == 'string', 'checksum.xxhash32 expects string')
	local st = M.new(seed)
	M.update(st, s)
	return M.digest(st)
end

function M.digest_hex(s)
	return hex8(M.xxhash32(s))
end

function M.verify_hex(s, expected)
	return M.digest_hex(s) == tostring(expected)
end

-- Expose for diagnostics/tests only. Production callers should use digest_hex.
M._test = {
	u32 = u32,
	mul32 = mul32,
	rol = rol,
	read_u32_le = read_u32_le,
	hex8 = hex8,
}

return M
