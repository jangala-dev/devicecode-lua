-- tests/unit/fabric/checksum_spec.lua

local checksum = require 'services.fabric.checksum'

local T = {}

function T.crc32_hex_matches_known_value()
	assert(checksum.crc32_hex('hello') == '3610a686')
end

function T.sha256_hex_matches_known_value()
	assert(checksum.sha256_hex('abc') ==
		'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
end

function T.sha256_hex_is_deterministic()
	local a = checksum.sha256_hex('firmware-bytes')
	local b = checksum.sha256_hex('firmware-bytes')
	assert(type(a) == 'string' and #a == 64)
	assert(a == b)
end

return T
