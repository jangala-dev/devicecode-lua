-- tests/unit/fabric/blob_source_spec.lua

local blob_source = require 'services.fabric.blob_source'

local T = {}

function T.from_string_exposes_expected_capabilities()
	local src = blob_source.from_string('fw.bin', 'hello', {
		format = 'bin',
		meta = { kind = 'firmware.rp2350' },
	})

	assert(blob_source.is_blob_source(src) == true)
	assert(src:name() == 'fw.bin')
	assert(src:size() == 5)
	assert(type(src:sha256hex()) == 'string' and #src:sha256hex() == 64)
	assert(src:format() == 'bin')

	local meta = src:meta()
	assert(type(meta) == 'table')
	assert(meta.kind == 'firmware.rp2350')
end

function T.reader_reads_until_eof()
	local src = blob_source.from_string('fw.bin', 'abcdef')
	local r = src:open()

	local a, aerr = r:read(2)
	assert(a ~= nil, tostring(aerr))
	assert(a == 'ab')

	local b, berr = r:read(3)
	assert(b ~= nil, tostring(berr))
	assert(b == 'cde')

	local c, cerr = r:read(10)
	assert(c ~= nil, tostring(cerr))
	assert(c == 'f')

	local d, derr = r:read(10)
	assert(d == nil)
	assert(derr == nil)

	local ok, e = r:close()
	assert(ok == true, tostring(e))
end

return T
