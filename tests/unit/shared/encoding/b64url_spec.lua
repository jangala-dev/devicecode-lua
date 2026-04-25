local b64url = require 'shared.encoding.b64url'

local T = {}

function T.encode_strips_padding_and_roundtrips_binary()
	local bytes = string.char(0, 1, 2, 250, 251, 252) .. 'hello'
	local text = b64url.encode(bytes)
	assert(type(text) == 'string')
	assert(text:find('=', 1, true) == nil)
	local out, err = b64url.decode(text)
	assert(out ~= nil, tostring(err))
	assert(out == bytes)
end

function T.decode_rejects_invalid_characters()
	local out, err = b64url.decode('abc$')
	assert(out == nil)
	assert(tostring(err):match('invalid_base64url_character'))
end

function T.encode_known_value()
	assert(b64url.encode('hello') == 'aGVsbG8')
end

return T
