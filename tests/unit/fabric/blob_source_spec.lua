local blob_source = require 'services.fabric.blob_source'
local checksum    = require 'services.fabric.checksum'
local runfibers   = require 'tests.support.run_fibers'

local T = {}

function T.from_string_reports_size_hash_and_reader_chunks()
	local src = blob_source.from_string('fw.bin', 'abcdef', { format = 'bin' })
	assert(src:name() == 'fw.bin')
	assert(src:size() == 6)
	assert(src:format() == 'bin')
	assert(src:sha256hex() == checksum.sha256_hex('abcdef'))

	local r = src:open()
	local a = assert(r:read(2))
	local b = assert(r:read(99))
	local c = r:read(1)

	assert(a == 'ab')
	assert(b == 'cdef')
	assert(c == nil)
end

function T.from_file_reads_bytes_eagerly()
	runfibers.run(function()
		local path = os.tmpname()
		local f = assert(io.open(path, 'wb'))
		f:write('hello-file')
		f:close()

		local src, err = blob_source.from_file(path, { format = 'bin' })
		os.remove(path)

		assert(src ~= nil, tostring(err))
		assert(src:size() == 10)
		assert(src:format() == 'bin')
		assert(blob_source.is_blob_source(src) == true)
	end)
end

return T
