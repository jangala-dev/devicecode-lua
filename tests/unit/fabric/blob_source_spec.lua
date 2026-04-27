local runfibers      = require 'tests.support.run_fibers'
local blob_source = require 'shared.blob_source'
local checksum    = require 'shared.hash.xxhash32'

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

function T.memory_sink_commits_to_stored_artefact()
	local sink = blob_source.memory_sink({ kind = 'firmware' })
	assert(sink:write_chunk(0, 'abc') == true)
	assert(sink:write_chunk(3, 'def') == true)
	assert(sink:size() == 6)
	assert(sink:checksum() == checksum.digest_hex('abcdef'))
	local artefact = assert((sink:commit()))
	assert(blob_source.is_stored_artefact(artefact) == true)
	assert(artefact:ref() == nil)
	assert(artefact:size() == 6)
	assert(artefact:checksum() == checksum.digest_hex('abcdef'))
	assert(artefact:meta().kind == 'firmware')
	local src = artefact:open_source()
	local s = assert(src:read_chunk(0, 99))
	assert(s == 'abcdef')
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

function T.copy_streams_source_into_sink_and_returns_stored_artefact()
	runfibers.run(function()
		local src = blob_source.from_string(('x'):rep(1000))
		local sink = blob_source.memory_sink({ purpose = 'copy-test' })
		local artefact = assert(blob_source.copy(src, sink, { chunk_size = 64 }))
		assert(artefact:size() == 1000)
		assert(artefact:checksum() == src:checksum())
		assert(artefact:meta().purpose == 'copy-test')
	end, { timeout = 2.0 })
end

return T
