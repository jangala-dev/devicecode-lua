local checksum = require 'shared.hash.xxhash32'

local T = {}

function T.xxhash32_matches_known_vectors()
	assert(checksum.xxhash32('') == 0x02cc5d05)
	assert(checksum.xxhash32('123456789') == 0x937bad67)
end

function T.digest_hex_matches_known_vectors()
	assert(checksum.digest_hex('') == '02cc5d05')
	assert(checksum.digest_hex('a') == '550d7456')
	assert(checksum.digest_hex('abc') == '32d153ff')
	assert(checksum.digest_hex('123456789') == '937bad67')
	assert(checksum.digest_hex('Nobody inspects the spammish repetition') == 'e2293b2f')
end

function T.verify_hex_reports_match()
	assert(checksum.verify_hex('abc', checksum.digest_hex('abc')) == true)
	assert(checksum.verify_hex('abc', 'deadbeef') == false)
end

return T
