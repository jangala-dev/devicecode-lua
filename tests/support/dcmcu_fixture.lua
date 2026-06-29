local cjson_ok, cjson = pcall(require, 'cjson.safe')
if not cjson_ok then cjson = require 'cjson' end

local M = {}

local function u16le(n)
	return string.char(n % 256, math.floor(n / 256) % 256)
end

local function u32le(n)
	return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

function M.make(image_id, payload, opts)
	opts = opts or {}
	payload = payload or string.rep('payload-', 64)
	local manifest = assert(cjson.encode({
		schema = 1,
		component = 'mcu',
		target = {
			product_family = opts.product_family or 'bigbox',
			hardware_profile = opts.hardware_profile or 'bb-v1-cm5-2',
			mcu_board_family = opts.mcu_board_family or 'rp2354a',
		},
		build = {
			version = opts.version or '15.0',
			build_id = opts.build_id or 'test-build',
			image_id = image_id or 'mcu-image-new',
		},
		payload = {
			format = 'raw-bin',
			length = #payload,
			sha256 = opts.payload_sha256 or string.rep('0', 64),
		},
		signing = {
			key_id = opts.key_id or 'test-key',
			sig_alg = 'ed25519',
		},
	}))
	local header_len = 32
	local header = 'DCMCUIMG' .. u16le(1) .. u16le(header_len) .. u32le(#manifest) .. string.rep('\0', header_len - 16)
	return header .. manifest .. payload
end

return M
