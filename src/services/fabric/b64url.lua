-- services/fabric/b64url.lua
--
-- Base64url codec without padding.
--
--   * encode(bytes) -> text
--   * decode(text)  -> bytes | nil, err
--
-- Uses RFC 4648 URL-safe alphabet and strips "=" padding.

local M = {}

local STD = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local URL = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'

local enc_map = {}
for i = 1, #URL do
	enc_map[i - 1] = URL:sub(i, i)
end

local dec_map = {}
for i = 1, #STD do
	dec_map[STD:sub(i, i)] = i - 1
end
dec_map['-'] = dec_map['+']
dec_map['_'] = dec_map['/']

function M.encode(bytes)
	if type(bytes) ~= 'string' then
		error('b64url.encode: bytes must be a string', 2)
	end

	local out = {}
	local len = #bytes
	local i = 1

	while i <= len do
		local a = bytes:byte(i) or 0
		local b = bytes:byte(i + 1) or 0
		local c = bytes:byte(i + 2) or 0

		local n = a * 65536 + b * 256 + c

		local c1 = math.floor(n / 262144) % 64
		local c2 = math.floor(n / 4096) % 64
		local c3 = math.floor(n / 64) % 64
		local c4 = n % 64

		out[#out + 1] = enc_map[c1]
		out[#out + 1] = enc_map[c2]

		if i + 1 <= len then
			out[#out + 1] = enc_map[c3]
		else
			out[#out + 1] = '='
		end

		if i + 2 <= len then
			out[#out + 1] = enc_map[c4]
		else
			out[#out + 1] = '='
		end

		i = i + 3
	end

	local s = table.concat(out)
	s = s:gsub('=+$', '')
	return s
end

function M.decode(text)
	if type(text) ~= 'string' then
		return nil, 'b64url.decode: text must be a string'
	end

	if text:find('[^%w%-%_]', 1) then
		return nil, 'b64url.decode: invalid character in input'
	end

	local s = text:gsub('%-', '+'):gsub('_', '/')
	local rem = #s % 4
	if rem == 1 then
		return nil, 'b64url.decode: invalid length'
	elseif rem == 2 then
		s = s .. '=='
	elseif rem == 3 then
		s = s .. '='
	end

	local out = {}
	local i = 1
	while i <= #s do
		local c1 = s:sub(i, i)
		local c2 = s:sub(i + 1, i + 1)
		local c3 = s:sub(i + 2, i + 2)
		local c4 = s:sub(i + 3, i + 3)

		local p1 = dec_map[c1]
		local p2 = dec_map[c2]
		local p3 = (c3 == '=') and nil or dec_map[c3]
		local p4 = (c4 == '=') and nil or dec_map[c4]

		if p1 == nil or p2 == nil or (c3 ~= '=' and p3 == nil) or (c4 ~= '=' and p4 == nil) then
			return nil, 'b64url.decode: invalid quartet'
		end

		local n = p1 * 262144 + p2 * 4096 + (p3 or 0) * 64 + (p4 or 0)

		local a = math.floor(n / 65536) % 256
		local b = math.floor(n / 256) % 256
		local c = n % 256

		out[#out + 1] = string.char(a)
		if c3 ~= '=' then out[#out + 1] = string.char(b) end
		if c4 ~= '=' then out[#out + 1] = string.char(c) end

		i = i + 4
	end

	return table.concat(out), nil
end

return M
