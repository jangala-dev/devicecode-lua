local blob_source = require 'services.fabric.blob_source'
local checksum    = require 'services.fabric.checksum'

local T = {}

function T.from_string_reports_chunks_and_checksum()
	local src = blob_source.from_string('abcdef')
	assert(src:size() == 6)
	assert(src:checksum() == checksum.digest_hex('abcdef'))
	local a, err1 = src:read_chunk(0, 2)
	local b, err2 = src:read_chunk(2, 99)
	local c, err3 = src:read_chunk(99, 1)
	assert(a == 'ab' and err1 == nil)
	assert(b == 'cdef' and err2 == nil)
	assert(c == '' and err3 == nil)
end

function T.memory_sink_accumulates_and_commits()
	local sink = blob_source.memory_sink()
	assert(sink:write_chunk(0, 'abc') == true)
	assert(sink:write_chunk(3, 'def') == true)
	assert(sink:size() == 6)
	assert(sink:tostring() == 'abcdef')
	assert(sink:checksum() == checksum.digest_hex('abcdef'))
	assert(sink:commit() == true)
	local st = sink:status()
	assert(st.size == 6)
	assert(st.committed == true)
	assert(st.aborted == nil or st.aborted == false)
end

function T.memory_sink_rejects_unexpected_offset()
	local sink = blob_source.memory_sink()
	local ok, err = sink:write_chunk(1, 'x')
	assert(ok == nil)
	assert(tostring(err):match('unexpected_offset'))
end

return T
