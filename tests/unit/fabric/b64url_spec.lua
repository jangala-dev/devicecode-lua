-- tests/unit/fabric/b64url_spec.lua

local b64url = require 'services.fabric.b64url'

local T = {}

function T.encode_omits_padding_and_round_trips_ascii()
	local enc = b64url.encode('hi')
	assert(type(enc) == 'string')
	assert(enc == 'aGk')
	assert(enc:find('=', 1, true) == nil)

	local dec, err = b64url.decode(enc)
	assert(dec ~= nil, tostring(err))
	assert(dec == 'hi')
end

function T.round_trips_binary_bytes()
	local raw = string.char(0, 1, 2, 3, 254, 255, 65, 66, 67)
	local enc = b64url.encode(raw)
	local dec, err = b64url.decode(enc)

	assert(dec ~= nil, tostring(err))
	assert(dec == raw)
end

function T.decode_rejects_invalid_characters()
	local dec, err = b64url.decode('YWJj$')
	assert(dec == nil)
	assert(type(err) == 'string')
	assert(err:find('invalid character', 1, true) ~= nil)
end

function T.decode_rejects_invalid_length()
	local dec, err = b64url.decode('a')
	assert(dec == nil)
	assert(type(err) == 'string')
	assert(err:find('invalid length', 1, true) ~= nil)
end

return T
