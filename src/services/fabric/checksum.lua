-- services/fabric/checksum.lua
--
-- Small, dependency-free xxHash32 helpers.
--
-- This provides a deterministic non-cryptographic integrity checksum for
-- transfer protocol use and tests without pulling in an external dependency.
-- It is not a security primitive.

local ok_bit32, bit32_mod = pcall(require, 'bit32')
local ok_bit, bit_mod = pcall(require, 'bit')

local bitops = ok_bit32 and bit32_mod or bit_mod
assert(bitops, 'services.fabric.checksum requires bit32 or bit')

local band   = assert(bitops.band,   'bit library missing band')
local bor    = assert(bitops.bor,    'bit library missing bor')
local bxor   = assert(bitops.bxor,   'bit library missing bxor')
local lshift = assert(bitops.lshift, 'bit library missing lshift')
local rshift = assert(bitops.rshift, 'bit library missing rshift')

local rol
if bitops.lrotate then
	rol = bitops.lrotate
elseif bitops.rol then
	rol = bitops.rol
else
	rol = function (x, n)
		n = n % 32
		return band(bor(lshift(x, n), rshift(x, 32 - n)), 0xffffffff)
	end
end

local M = {}

local P1 = 0x9E3779B1
local P2 = 0x85EBCA77
local P3 = 0xC2B2AE3D
local P4 = 0x27D4EB2F
local P5 = 0x165667B1

local TWO32 = 4294967296

local function u32(n)
	return band(n, 0xffffffff)
end

local function hex8(n)
	n = u32(n)
	-- LuaJIT/bit may format signed 32-bit values as negative unless adjusted.
	if n < 0 then
		n = n + TWO32
	end
	return ('%08x'):format(n)
end

-- Exact 32-bit multiplication modulo 2^32 using 16-bit limbs.
local function mul32(a, b)
	a = u32(a)
	b = u32(b)

	local a_lo = band(a, 0xffff)
	local a_hi = band(rshift(a, 16), 0xffff)
	local b_lo = band(b, 0xffff)
	local b_hi = band(rshift(b, 16), 0xffff)

	local lo  = a_lo * b_lo
	local mid = a_hi * b_lo + a_lo * b_hi

	return u32(lo + lshift(band(mid, 0xffff), 16))
end

local function read_u32_le(s, i)
	local b1, b2, b3, b4 = s:byte(i, i + 3)
	return bor(
		b1 or 0,
		lshift(b2 or 0, 8),
		lshift(b3 or 0, 16),
		lshift(b4 or 0, 24)
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
	if s == '' then
		return state
	end

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

return M
