-- services/fabric/checksum.lua
--
-- Checksums for blob transfer.
--
-- Provides:
--   * crc32_hex(bytes)
--   * sha256_hex(bytes)
--
-- SHA-256 uses luaossl if available, falling back to a pure-Lua
-- implementation that requires bit32 or LuaJIT's bit library.

local M = {}

local ok_bit32, bit32lib = pcall(require, 'bit32')
local ok_bit, bitlib = pcall(require, 'bit')

local band, bor, bxor, bnot, rshift, lshift, rrotate

if ok_bit32 and type(bit32lib) == 'table' then
	band    = bit32lib.band
	bor     = bit32lib.bor
	bxor    = bit32lib.bxor
	bnot    = bit32lib.bnot
	rshift  = bit32lib.rshift
	lshift  = bit32lib.lshift
	rrotate = bit32lib.rrotate or function(x, n)
		n = n % 32
		return bor(rshift(x, n), lshift(x, 32 - n))
	end
elseif ok_bit and type(bitlib) == 'table' then
	band    = bitlib.band
	bor     = bitlib.bor
	bxor    = bitlib.bxor
	bnot    = bitlib.bnot
	rshift  = bitlib.rshift
	lshift  = bitlib.lshift
	rrotate = bitlib.ror or function(x, n)
		n = n % 32
		return bor(rshift(x, n), lshift(x, 32 - n))
	end
else
	error('services.fabric.checksum requires bit32 or bit')
end

local function add_u32(...)
	local s = 0
	for i = 1, select('#', ...) do
		s = (s + select(i, ...)) % 4294967296
	end
	return s
end

----------------------------------------------------------------------
-- CRC32
----------------------------------------------------------------------

local crc32_tab = {}
do
	for i = 0, 255 do
		local c = i
		for _ = 1, 8 do
			if band(c, 1) ~= 0 then
				c = bxor(rshift(c, 1), 0xEDB88320)
			else
				c = rshift(c, 1)
			end
		end
		crc32_tab[i] = c
	end
end

function M.crc32(bytes)
	if type(bytes) ~= 'string' then
		error('checksum.crc32: bytes must be a string', 2)
	end

	local crc = 0xFFFFFFFF
	for i = 1, #bytes do
		local b = bytes:byte(i)
		local idx = band(bxor(crc, b), 0xFF)
		crc = bxor(rshift(crc, 8), crc32_tab[idx])
	end
	return bxor(crc, 0xFFFFFFFF)
end

function M.crc32_hex(bytes)
	return string.format('%08x', M.crc32(bytes))
end

----------------------------------------------------------------------
-- SHA-256 backends
----------------------------------------------------------------------

local function bytes_to_hex(s)
	return (s:gsub('.', function(ch)
		return string.format('%02x', ch:byte())
	end))
end

local function sha256_luaossl(bytes)
	-- luaossl exposes digest helpers under openssl.digest.
	local ok, digest = pcall(require, 'openssl.digest')
	if not ok or type(digest) ~= 'table' then
		return nil
	end

	-- Preferred streaming API.
	if type(digest.new) == 'function' then
		local ctx = digest.new('sha256')
		if ctx and type(ctx.update) == 'function' and type(ctx.final) == 'function' then
			ctx:update(bytes)
			local out = ctx:final()
			if type(out) == 'string' and #out == 32 then
				return bytes_to_hex(out)
			end
			if type(out) == 'string' and #out == 64 then
				return out:lower()
			end
		end
	end

	-- Some luaossl builds also expose a one-shot helper.
	if type(digest.digest) == 'function' then
		local out = digest.digest('sha256', bytes)
		if type(out) == 'string' and #out == 32 then
			return bytes_to_hex(out)
		end
		if type(out) == 'string' and #out == 64 then
			return out:lower()
		end
	end

	return nil
end

local K = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
	0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
	0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
	0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
	0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
	0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
	0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
	0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
	0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function Ch(x, y, z) return bxor(band(x, y), band(bnot(x), z)) end
local function Maj(x, y, z) return bxor(bxor(band(x, y), band(x, z)), band(y, z)) end
local function S0(x) return bxor(bxor(rrotate(x, 2), rrotate(x, 13)), rrotate(x, 22)) end
local function S1(x) return bxor(bxor(rrotate(x, 6), rrotate(x, 11)), rrotate(x, 25)) end
local function s0(x) return bxor(bxor(rrotate(x, 7), rrotate(x, 18)), rshift(x, 3)) end
local function s1(x) return bxor(bxor(rrotate(x, 17), rrotate(x, 19)), rshift(x, 10)) end

local function be_u32(s, i)
	local a, b, c, d = s:byte(i, i + 3)
	return ((a * 256 + b) * 256 + c) * 256 + d
end

local function u32_hex(x)
	return string.format('%08x', x)
end

local function sha256_pure(bytes)
	local H = {
		0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
		0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
	}

	local len = #bytes
	local bit_len = len * 8
	local high = math.floor(bit_len / 4294967296)
	local low = bit_len % 4294967296

	local msg = { bytes }
	msg[#msg + 1] = string.char(0x80)

	local rem = (len + 1) % 64
	local pad = (rem <= 56) and (56 - rem) or (56 + 64 - rem)
	if pad > 0 then
		msg[#msg + 1] = string.rep('\0', pad)
	end

	msg[#msg + 1] = string.char(
		band(rshift(high, 24), 0xFF),
		band(rshift(high, 16), 0xFF),
		band(rshift(high, 8), 0xFF),
		band(high, 0xFF),
		band(rshift(low, 24), 0xFF),
		band(rshift(low, 16), 0xFF),
		band(rshift(low, 8), 0xFF),
		band(low, 0xFF)
	)

	local s = table.concat(msg)

	local W = {}
	for chunk = 1, #s, 64 do
		for i = 0, 15 do
			W[i] = be_u32(s, chunk + i * 4)
		end
		for i = 16, 63 do
			W[i] = add_u32(s1(W[i - 2]), W[i - 7], s0(W[i - 15]), W[i - 16])
		end

		local a, b, c, d, e, f, g, h =
			H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]

		for i = 0, 63 do
			local T1 = add_u32(h, S1(e), Ch(e, f, g), K[i + 1], W[i])
			local T2 = add_u32(S0(a), Maj(a, b, c))

			h = g
			g = f
			f = e
			e = add_u32(d, T1)
			d = c
			c = b
			b = a
			a = add_u32(T1, T2)
		end

		H[1] = add_u32(H[1], a)
		H[2] = add_u32(H[2], b)
		H[3] = add_u32(H[3], c)
		H[4] = add_u32(H[4], d)
		H[5] = add_u32(H[5], e)
		H[6] = add_u32(H[6], f)
		H[7] = add_u32(H[7], g)
		H[8] = add_u32(H[8], h)
	end

	return table.concat({
		u32_hex(H[1]), u32_hex(H[2]), u32_hex(H[3]), u32_hex(H[4]),
		u32_hex(H[5]), u32_hex(H[6]), u32_hex(H[7]), u32_hex(H[8]),
	})
end

function M.sha256_hex(bytes)
	if type(bytes) ~= 'string' then
		error('checksum.sha256_hex: bytes must be a string', 2)
	end
	return sha256_luaossl(bytes) or sha256_pure(bytes)
end

return M
