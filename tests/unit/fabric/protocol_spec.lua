local protocol = require 'services.fabric.protocol'

local T = {}

function T.encode_decode_roundtrips_call_frame()
	local line, err = protocol.encode_line({
		type = 'call',
		id = 'id-1',
		topic = { 'rpc', 'svc', 'echo' },
		payload = { x = 1 },
	})
	assert(line ~= nil, tostring(err))
	local msg, derr = protocol.decode_line(line)
	assert(msg ~= nil, tostring(derr))
	assert(msg.type == 'call')
	assert(msg.id == 'id-1')
	assert(msg.topic[1] == 'rpc')
	assert(msg.payload.x == 1)
	assert(protocol.classify(msg) == 'rpc')
	assert(protocol.dispatch_lane(msg) == 'rpc')
end

function T.validate_rejects_non_boolean_pub_retain()
	local msg, err = protocol.validate({
		type = 'pub',
		topic = { 'a' },
		payload = {},
		retain = 'yes',
	})
	assert(msg == nil)
	assert(tostring(err):match('missing_retain'))
end

function T.validate_accepts_transfer_begin()
	local msg, err = protocol.validate({
		type = 'xfer_begin',
		xfer_id = 'x1',
		size = 3,
		checksum = 'deadbeef',
	})
	assert(msg ~= nil, tostring(err))
	assert(msg.type == 'xfer_begin')
	assert(protocol.classify(msg) == 'control')
	assert(protocol.dispatch_lane(msg) == 'transfer')
end

function T.validate_rejects_malformed_transfer_control_frames()
	local bad1, err1 = protocol.validate({
		type = 'xfer_ready',
	})
	assert(bad1 == nil)
	assert(tostring(err1):match('missing_xfer_id'))

	local bad2, err2 = protocol.validate({
		type = 'xfer_commit',
		xfer_id = 'x1',
		size = 3,
	})
	assert(bad2 == nil)
	assert(tostring(err2):match('invalid_xfer_checksum'))

	local bad3, err3 = protocol.validate({
		type = 'xfer_done',
	})
	assert(bad3 == nil)
	assert(tostring(err3):match('missing_xfer_id'))

	local bad4, err4 = protocol.validate({
		type = 'xfer_abort',
		xfer_id = 'x1',
		err = false,
	})
	assert(bad4 == nil)
	assert(tostring(err4):match('invalid_xfer_err'))
end

function T.writer_item_sets_cost_and_class()
	local item, err = protocol.writer_item('rpc', {
		type = 'reply',
		id = 'abc',
		ok = true,
		value = { hi = 'there' },
	})
	assert(item ~= nil, tostring(err))
	assert(item.class == 'rpc')
	assert(type(item.cost) == 'number' and item.cost > 0)
	assert(type(item.line) == 'string')
end

return T
