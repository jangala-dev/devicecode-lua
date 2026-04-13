local T = {}

local SHA256_ABC = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
local CRC32_123456789 = 'cbf43926'

local function reload_checksum_with_forced_missing_luaossl()
	local orig_checksum = package.loaded['services.fabric.checksum']
	local orig_preload  = package.preload['openssl.digest']
	local orig_loaded   = package.loaded['openssl.digest']

	package.loaded['services.fabric.checksum'] = nil
	package.loaded['openssl.digest'] = nil
	package.preload['openssl.digest'] = function()
		error('forced missing luaossl', 0)
	end

	local ok, mod = pcall(require, 'services.fabric.checksum')

	package.loaded['services.fabric.checksum'] = orig_checksum
	package.loaded['openssl.digest'] = orig_loaded
	package.preload['openssl.digest'] = orig_preload

	if not ok then
		error(mod, 0)
	end

	return mod
end

function T.sha256_matches_known_vector()
	local checksum = require 'services.fabric.checksum'
	assert(checksum.sha256_hex('abc') == SHA256_ABC)
end

function T.crc32_matches_known_vector()
	local checksum = require 'services.fabric.checksum'
	assert(checksum.crc32_hex('123456789') == CRC32_123456789)
end

function T.sha256_falls_back_to_pure_lua_when_luaossl_is_unavailable()
	local checksum = reload_checksum_with_forced_missing_luaossl()
	assert(checksum.sha256_hex('abc') == SHA256_ABC)
end

return T
