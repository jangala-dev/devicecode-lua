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

return T
