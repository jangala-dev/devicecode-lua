-- services/fabric/b64url.lua
--
-- Small base64url codec used by fabric for transport-safe opaque data.
--
-- Notes:
--   * this is intentionally tiny and dependency-free
--   * it is used for transport-safe opaque payload fragments
--   * it is not intended as a general-purpose crypto or serialisation utility

local M = {}

local ENC = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local DEC = {}
for i = 1, #ENC do
	DEC[ENC:sub(i, i)] = i - 1
end

local function to_bits(n, width)
	local t = {}
	for i = width - 1, 0, -1 do
		t[#t + 1] = math.floor(n / (2 ^ i)) % 2
	end
	return t
end

local function from_bits(bits, i, width)
	local n = 0
	for k = 0, width - 1 do
		n = n * 2 + bits[i + k]
	end
	return n
end

function M.encode(s)
	assert(type(s) == 'string', 'b64url.encode expects string')

	local bits = {}
	for i = 1, #s do
		local bb = to_bits(s:byte(i), 8)
		for j = 1, #bb do
			bits[#bits + 1] = bb[j]
		end
	end

	while (#bits % 6) ~= 0 do
		bits[#bits + 1] = 0
	end

	local out = {}
	for i = 1, #bits, 6 do
		local idx = from_bits(bits, i, 6) + 1
		out[#out + 1] = ENC:sub(idx, idx)
	end

	local pad = ({ '', '==', '=' })[#s % 3 + 1]
	local encoded = table.concat(out) .. pad
	encoded = encoded:gsub('+', '-')
	encoded = encoded:gsub('/', '_')
	encoded = encoded:gsub('=', '')
	return encoded
end

function M.decode(s)
	assert(type(s) == 'string', 'b64url.decode expects string')

	s = s:gsub('-', '+'):gsub('_', '/')

	local rem = #s % 4
	if rem == 2 then
		s = s .. '=='
	elseif rem == 3 then
		s = s .. '='
	elseif rem == 1 then
		return nil, 'invalid_base64url_length'
	end

	local bits = {}
	for i = 1, #s do
		local ch = s:sub(i, i)
		if ch ~= '=' then
			local v = DEC[ch]
			if v == nil then
				return nil, 'invalid_base64url_character'
			end
			local bb = to_bits(v, 6)
			for j = 1, #bb do
				bits[#bits + 1] = bb[j]
			end
		end
	end

	local out = {}
	for i = 1, #bits - 7, 8 do
		out[#out + 1] = string.char(from_bits(bits, i, 8))
	end

	return table.concat(out), nil
end

return M
