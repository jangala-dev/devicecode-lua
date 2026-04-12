local checksum = require 'services.fabric.checksum'

local T = {}

function T.crc32_matches_known_vector()
	assert(checksum.crc32_hex('123456789') == 'cbf43926')
end

function T.sha256_matches_known_vector()
	assert(checksum.sha256_hex('abc') == 'ba7816bf8f01cfea414140de5dae2223'
		.. 'b00361a396177a9cb410ff61f20015ad')
end

return T
