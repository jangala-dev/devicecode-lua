local protocol = require 'services.fabric.protocol'

local T = {}

function T.encode_decode_roundtrips_call_message()
	local line, err = protocol.encode_line(protocol.call('id-1', { 'rpc', 'svc', 'echo' }, { x = 1 }, 5000))
	assert(line ~= nil, tostring(err))

	local msg, derr = protocol.decode_line(line)
	assert(msg ~= nil, tostring(derr))
	assert(msg.t == 'call')
	assert(msg.id == 'id-1')
	assert(msg.topic[1] == 'rpc')
	assert(msg.payload.x == 1)
end

function T.validate_rejects_non_concrete_call_topics()
	local msg, err = protocol.validate_message({
		t = 'call',
		id = 'id-1',
		topic = { 'rpc', '+', 'echo' },
		payload = {},
	})

	assert(msg == nil)
	assert(tostring(err):match('concrete'))
end

function T.validate_accepts_transfer_begin()
	local msg, err = protocol.validate_message({
		t = 'xfer_begin',
		id = 'x1',
		kind = 'firmware',
		name = 'fw.bin',
		format = 'bin',
		enc = 'b64url',
		size = 3,
		chunk_raw = 3,
		chunks = 1,
		sha256 = 'abc',
		meta = { board = 'x' },
	})

	assert(msg ~= nil, tostring(err))
	assert(msg.t == 'xfer_begin')
	assert(msg.meta.board == 'x')
end

return T
