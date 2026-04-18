local checksum = require 'services.fabric.checksum'

local T = {}

function T.adler32_matches_known_vector()
	assert(checksum.adler32('123456789') == 0x091e01de)
end

function T.digest_hex_matches_known_vector()
	assert(checksum.digest_hex('123456789') == '091e01de')
end

function T.verify_hex_reports_match()
	assert(checksum.verify_hex('abc', checksum.digest_hex('abc')) == true)
	assert(checksum.verify_hex('abc', 'deadbeef') == false)
end

return T
