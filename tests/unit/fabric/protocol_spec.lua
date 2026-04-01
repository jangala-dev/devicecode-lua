local protocol = require 'services.fabric.protocol'

local T = {}

function T.hello_includes_session_identity_and_protocol_version()
	local msg = protocol.hello('cm5-local', 'mcu-1', {
		pub  = true,
		call = true,
	}, {
		sid = 'local-sid-1',
	})

	assert(type(msg) == 'table')
	assert(msg.t == 'hello')
	assert(msg.node == 'cm5-local')
	assert(msg.peer == 'mcu-1')
	assert(msg.sid == 'local-sid-1')
	assert(type(msg.proto) == 'number')
	assert(type(msg.caps) == 'table')
	assert(msg.caps.pub == true)
	assert(msg.caps.call == true)
end

function T.hello_ack_can_carry_session_identity()
	local msg = protocol.hello_ack('mcu-1', {
		sid = 'peer-sid-1',
	})

	assert(type(msg) == 'table')
	assert(msg.t == 'hello_ack')
	assert(msg.node == 'mcu-1')
	assert(msg.sid == 'peer-sid-1')
	assert(type(msg.proto) == 'number')
	assert(msg.ok == true)
end

function T.ping_and_pong_can_carry_session_identity()
	local ping = protocol.ping({ sid = 'local-sid-1' })
	local pong = protocol.pong({ sid = 'peer-sid-1' })

	assert(ping.t == 'ping')
	assert(ping.sid == 'local-sid-1')
	assert(type(ping.ts) == 'number')

	assert(pong.t == 'pong')
	assert(pong.sid == 'peer-sid-1')
	assert(type(pong.ts) == 'number')
end

function T.encode_decode_round_trip_preserves_hello_fields()
	local raw_in = protocol.hello('cm5-local', 'mcu-1', {
		pub = true,
	}, {
		sid = 'local-sid-1',
	})

	local line, err = protocol.encode_line(raw_in)
	assert(line ~= nil, tostring(err))

	local decoded, derr = protocol.decode_line(line)
	assert(decoded ~= nil, tostring(derr))

	assert(decoded.t == 'hello')
	assert(decoded.node == 'cm5-local')
	assert(decoded.peer == 'mcu-1')
	assert(decoded.sid == 'local-sid-1')
	assert(type(decoded.proto) == 'number')
	assert(type(decoded.caps) == 'table')
	assert(decoded.caps.pub == true)
end

function T.validate_accepts_valid_call()
	local msg, err = protocol.validate_message({
		t          = 'call',
		id         = 'abc-1',
		topic      = { 'rpc', 'hal', 'read_state' },
		payload    = { ns = 'config', key = 'services' },
		timeout_ms = 500,
	})

	assert(msg ~= nil, tostring(err))
	assert(msg.t == 'call')
	assert(msg.id == 'abc-1')
	assert(msg.topic[1] == 'rpc')
	assert(msg.topic[2] == 'hal')
	assert(msg.topic[3] == 'read_state')
	assert(type(msg.payload) == 'table')
	assert(msg.payload.ns == 'config')
	assert(msg.timeout_ms == 500)
end

function T.validate_rejects_non_concrete_call_topic()
	local msg, err = protocol.validate_message({
		t       = 'call',
		id      = 'abc-1',
		topic   = { 'rpc', '+', 'read_state' },
		payload = {},
	})

	assert(msg == nil)
	assert(type(err) == 'string')
	assert(err:find('concrete', 1, true) ~= nil)
end

function T.validate_rejects_unknown_message_type()
	local msg, err = protocol.validate_message({
		t = 'banana',
	})

	assert(msg == nil)
	assert(type(err) == 'string')
	assert(err:find('unknown message type', 1, true) ~= nil)
end

function T.validate_rejects_pub_with_bad_topic_shape()
	local msg, err = protocol.validate_message({
		t       = 'pub',
		topic   = 'state/health',
		payload = { ok = true },
		retain  = true,
	})

	assert(msg == nil)
	assert(type(err) == 'string')
	assert(err:find('dense array', 1, true) ~= nil)
end

function T.validate_rejects_hello_without_sid()
	local msg, err = protocol.validate_message({
		t     = 'hello',
		node  = 'mcu-1',
		peer  = 'cm5-local',
		proto = 1,
		caps  = {},
	})

	assert(msg == nil)
	assert(type(err) == 'string')
	assert(err:find('hello.sid', 1, true) ~= nil)
end

return T
