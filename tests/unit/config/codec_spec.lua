-- tests/config_codec_spec.lua

local codec = require 'services.config.codec'

local T = {}

function T.decode_rejects_non_table_root()
	local out, err = codec.decode_blob_strict('"x"')
	assert(out == nil)
	assert(tostring(err):match('root must be a table'))
end

function T.decode_requires_schema()
	local blob = [[{"net":{"rev":1,"data":{"foo":"bar"}}}]]
	local out, err = codec.decode_blob_strict(blob)
	assert(out == nil)
	assert(tostring(err):match('data%.schema'))
end

function T.decode_strips_json_nulls()
	local blob = [[{"net":{"rev":1,"data":{"schema":"x","a":null,"b":1}}}]]
	local out, err = codec.decode_blob_strict(blob)
	assert(out ~= nil, tostring(err))
	assert(out.net.data.a == nil)
	assert(out.net.data.b == 1)
end

function T.encode_is_strict()
	local t = {}
	t.self = t
	local s, err = codec.encode_blob(t)
	assert(s == nil)
	assert(tostring(err):match('json_encode_failed'))
end

function T.deepcopy_plain_copies_nested_tables()
	local x = { a = { b = 1 } }
	local y = codec.deepcopy_plain(x)
	assert(y ~= x)
	assert(y.a ~= x.a)
	y.a.b = 2
	assert(x.a.b == 1)
end

return T
