-- tests/services/fabric/test_protocol.lua

local protocol = require 'services.fabric.protocol'

local tests = {}

local function fail(msg)
	error(msg or 'assertion failed', 2)
end

local function assert_eq(a, b, msg)
	if a ~= b then
		fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a)))
	end
end

local function assert_nil(v, msg)
	if v ~= nil then
		fail(msg or ('expected nil, got ' .. tostring(v)))
	end
end

local function assert_not_nil(v, msg)
	if v == nil then
		fail(msg or 'expected non-nil value')
	end
end

function tests.test_classifies_reference_frame_types()
	assert_eq(protocol.classify({ type = 'hello' }), 'session_control')
	assert_eq(protocol.classify({ type = 'pub' }), 'rpc')
	assert_eq(protocol.classify({ type = 'xfer_chunk' }), 'transfer_bulk')

	assert_eq(protocol.dispatch_lane({ type = 'hello' }), 'session_control')
	assert_eq(protocol.dispatch_lane({ type = 'reply' }), 'rpc')
	assert_eq(protocol.dispatch_lane({ type = 'xfer_chunk' }), 'transfer')
end

function tests.test_validate_rejects_unknown_type()
	local ok, err = protocol.validate({ type = 'wat' })

	assert_nil(ok)
	assert_eq(err, 'invalid_frame_type')
end

function tests.test_validate_rejects_non_string_frame_keys()
	local ok, err = protocol.validate({
		type = 'ping',
		[1] = 'bad',
	})

	assert_nil(ok)
	assert_eq(err, 'invalid_frame_type')
end

function tests.test_hello_requires_proto_sid_and_uses_node_wire_field()
	local ok, err = protocol.validate({ type = 'hello' })

	assert_nil(ok)
	assert_eq(err, 'missing_proto')

	ok, err = protocol.validate({
		type = 'hello',
		proto = protocol.PROTO,
		node = 'node-a',
	})

	assert_nil(ok)
	assert_eq(err, 'missing_sid')

	ok, err = protocol.validate({
		type = 'hello',
		proto = protocol.PROTO,
		sid = 'sid-1',
		node = 'node-a',
	})

	assert_not_nil(ok)
	assert_nil(err)

	ok, err = protocol.validate({
		type = 'hello',
		proto = protocol.PROTO,
		sid = 'sid-1',
		node_id = 'node-a',
	})

	assert_nil(ok)
	assert_eq(err, 'unknown_frame_field: node_id')
end


function tests.test_proto_field_is_reserved_for_session_hello_frames()
	local ok, err = protocol.validate({
		type = 'pub',
		proto = protocol.PROTO,
		topic = { 'state', 'self' },
		payload = {},
		retain = true,
	})

	assert_nil(ok)
	assert_eq(err, 'unknown_frame_field: proto')
end

function tests.test_ping_and_pong_require_sid()
	local ok, err = protocol.validate({ type = 'ping' })
	assert_nil(ok)
	assert_eq(err, 'missing_sid')

	ok, err = protocol.validate({ type = 'pong', sid = 'sid-1' })
	assert_not_nil(ok)
	assert_nil(err)
end

function tests.test_pub_requires_dense_scalar_topic_and_boolean_retain()
	local ok, err = protocol.validate({
		type = 'pub',
		topic = { 'raw', 'member', 'a' },
		payload = { value = 1 },
		retain = true,
	})

	assert_not_nil(ok)
	assert_nil(err)

	ok, err = protocol.validate({
		type = 'pub',
		topic = { 'raw', {}, 'a' },
		retain = true,
	})

	assert_nil(ok)
	assert_eq(err, 'invalid_topic')

	ok, err = protocol.validate({
		type = 'pub',
		topic = { 'raw', 'member', 'a' },
	})

	assert_nil(ok)
	assert_eq(err, 'missing_retain')
end

function tests.test_call_and_reply_validation()
	local ok, err = protocol.validate({
		type = 'call',
		id = 'call-1',
		topic = { 'cap', 'x', 'main', 'rpc', 'do' },
		payload = { n = 1 },
	})

	assert_not_nil(ok)
	assert_nil(err)

	ok, err = protocol.validate({
		type = 'reply',
		id = 'call-1',
		ok = false,
		err = 'nope',
	})

	assert_not_nil(ok)
	assert_nil(err)

	ok, err = protocol.validate({
		type = 'reply',
		id = 'call-1',
		ok = false,
		err = {},
	})

	assert_nil(ok)
	assert_eq(err, 'invalid_reply_err')
end


function tests.test_rejects_legacy_checksum_field()
	local ok, err = protocol.validate({
		type = 'xfer_commit',
		xfer_id = 'x1',
		size = 3,
		digest_alg = protocol.DIGEST_ALG,
		digest = protocol.digest_hex('abc'),
		checksum = 'legacy',
	})

	assert_nil(ok)
	assert_eq(err, 'unknown_frame_field: checksum')
end

function tests.test_transfer_control_validation()
	local ok, err = protocol.validate({
		type = 'xfer_begin',
		xfer_id = 'x1',
		target = 'slot-a',
		size = 123,
		digest_alg = protocol.DIGEST_ALG,
		digest = '1a2b3c4d',
	})

	assert_not_nil(ok)
	assert_nil(err)

	ok, err = protocol.validate({
		type = 'xfer_begin',
		xfer_id = 'x1',
		target = 'slot-a',
		size = 123,
		digest_alg = 'sha256',
		digest = 'abc',
	})

	assert_nil(ok)
	assert_eq(err, 'unsupported_digest_alg')

	ok, err = protocol.validate({
		type = 'xfer_need',
		xfer_id = 'x1',
		next = -1,
	})

	assert_nil(ok)
	assert_eq(err, 'invalid_next')
end

function tests.test_encode_decode_regular_frame_roundtrip()
	local frame = {
		type = 'pub',
		topic = { 'raw', 'member', 'node-a', 'state', 'temperature' },
		payload = { value = 20 },
		retain = true,
	}

	local line, err = protocol.encode_line(frame)

	assert_not_nil(line)
	assert_nil(err)

	local decoded, derr = protocol.decode_line(line)

	assert_not_nil(decoded)
	assert_nil(derr)
	assert_eq(decoded.type, 'pub')
	assert_eq(decoded.topic[1], 'raw')
	assert_eq(decoded.topic[3], 'node-a')
	assert_eq(decoded.payload.value, 20)
	assert_eq(decoded.retain, true)
end

function tests.test_encode_decode_xfer_chunk_roundtrip_preserves_bytes()
	local frame = {
		type = 'xfer_chunk',
		xfer_id = 'xfer-1',
		offset = 5,
		data = 'abc\0def',
		chunk_digest = protocol.chunk_digest('abc\0def'),
	}

	local line, err = protocol.encode_line(frame)

	assert_not_nil(line)
	assert_nil(err)

	local decoded, derr = protocol.decode_line(line)

	assert_not_nil(decoded)
	assert_nil(derr)
	assert_eq(decoded.type, 'xfer_chunk')
	assert_eq(decoded.xfer_id, 'xfer-1')
	assert_eq(decoded.offset, 5)
	assert_eq(decoded.data, 'abc\0def')
	assert_eq(decoded.chunk_digest, protocol.chunk_digest('abc\0def'))
end

function tests.test_semantic_xfer_chunk_digest_is_verified()
	local ok, err = protocol.validate({
		type = 'xfer_chunk',
		xfer_id = 'xfer-1',
		offset = 0,
		data = 'abc',
		chunk_digest = '00000000',
	})

	assert_nil(ok)
	assert_eq(err, 'chunk_digest_mismatch')

	ok, err = protocol.validate({
		type = 'xfer_chunk',
		xfer_id = 'xfer-1',
		offset = 0,
		data = 'abc',
		chunk_digest = protocol.chunk_digest('abc'),
	})

	assert_not_nil(ok)
	assert_nil(err)
end

function tests.test_encode_line_rejects_semantic_xfer_chunk_digest_mismatch()
	local line, err = protocol.encode_line({
		type = 'xfer_chunk',
		xfer_id = 'xfer-1',
		offset = 0,
		data = 'abc',
		chunk_digest = '00000000',
	})

	assert_nil(line)
	assert_eq(err, 'chunk_digest_mismatch')
end


function tests.test_xfer_chunk_requires_chunk_digest_and_strict_unpadded_b64url()
	local ok, err = protocol.validate({
		type = 'xfer_chunk',
		xfer_id = 'xfer-1',
		offset = 0,
		data = 'abc',
	})

	assert_nil(ok)
	assert_eq(err, 'missing_chunk_digest')

	local line = '{"type":"xfer_chunk","xfer_id":"xfer-1","offset":0,"data":"YQ==","chunk_digest":"' .. protocol.chunk_digest('a') .. '"}'
	local frame, derr = protocol.decode_line(line)
	assert_nil(frame)
	assert_eq(derr, 'invalid_chunk_encoding: invalid_base64url_unpadded')
end

function tests.test_decode_line_preserves_xfer_chunk_digest_mismatch_for_receiver_retry()
	local line = '{"type":"xfer_chunk","xfer_id":"xfer-1","offset":0,"data":"YQ","chunk_digest":"00000000"}'
	local frame, err = protocol.decode_line(line)

	assert_not_nil(frame)
	assert_nil(err)
	assert_eq(frame.type, 'xfer_chunk')
	assert_eq(frame.xfer_id, 'xfer-1')
	assert_eq(frame.offset, 0)
	assert_eq(frame.data, 'a')
	assert_eq(frame.chunk_digest, '00000000')

	local ok, verr = protocol.validate(frame)
	assert_nil(ok)
	assert_eq(verr, 'chunk_digest_mismatch')
end

function tests.test_decode_line_rejects_non_json()
	local frame, err = protocol.decode_line('{')

	assert_nil(frame)
	assert_not_nil(err)
end

function tests.test_constructors_validate_before_returning()
	local frame, err = protocol.xfer_need('x1', 10)

	assert_not_nil(frame)
	assert_nil(err)
	assert_eq(frame.type, 'xfer_need')
	assert_eq(frame.next, 10)

	frame, err = protocol.xfer_need('x1', -10)

	assert_nil(frame)
	assert_eq(err, 'invalid_next')
end

function tests.test_hello_accepts_reserved_identity_and_auth_objects()
	local frame = assert(protocol.hello('sid-1', 'cm5', { id = 'claim' }, { scheme = 'reserved' }))
	local line, err = protocol.encode_line(frame)
	assert_not_nil(line)
	assert_nil(err)

	local decoded, derr = protocol.decode_line(line)
	assert_not_nil(decoded)
	assert_nil(derr)
	assert_eq(decoded.proto, protocol.PROTO)
	assert_eq(decoded.node, 'cm5')
	assert_eq(decoded.identity.id, 'claim')
	assert_eq(decoded.auth.scheme, 'reserved')
end


function tests.test_decode_line_rejects_non_canonical_base64url_chunk_data()
	-- "AB" decodes to the same byte as canonical "AA" with non-zero discarded
	-- pad bits. fabric-jsonl/1 accepts only the canonical unpadded form.
	local line = '{"type":"xfer_chunk","xfer_id":"xfer-1","offset":0,"data":"AB","chunk_digest":"' .. protocol.chunk_digest('\0') .. '"}'
	local frame, err = protocol.decode_line(line)

	assert_nil(frame)
	assert_eq(err, 'invalid_chunk_encoding: non_canonical_base64url')
end


function tests.test_protocol_digest_helpers_use_xxhash32_seed_zero_vectors()
	assert_eq(protocol.DIGEST_ALG, 'xxhash32')
	assert_eq(protocol.digest_hex(''), '02cc5d05')
	assert_eq(protocol.digest_hex('abc'), '32d153ff')
	assert_eq(protocol.chunk_digest('abc\0def'), '7955e6e5')
end

function tests.test_unknown_top_level_fields_are_rejected_but_identity_auth_are_extensible()
	local ok, err = protocol.validate({
		type = 'hello',
		proto = protocol.PROTO,
		sid = 'sid-1',
		node = 'mcu',
		identity = { id = 'claimed-peer', future = { ignored = true } },
		auth = { scheme = 'reserved', future = { proof = nil } },
	})
	assert_not_nil(ok)
	assert_nil(err)

	ok, err = protocol.validate({
		type = 'hello',
		proto = protocol.PROTO,
		sid = 'sid-1',
		node = 'mcu',
		future = true,
	})
	assert_nil(ok)
	assert_eq(err, 'unknown_frame_field: future')

	local line = '{"type":"reply","id":"call-1","ok":true,"future":true}'
	local frame, derr = protocol.decode_line(line)
	assert_nil(frame)
	assert_eq(derr, 'unknown_frame_field: future')
end

function tests.test_transfer_digests_are_strict_xxhash32_hex()
	local ok, err = protocol.validate({
		type = 'xfer_begin',
		xfer_id = 'xfer-1',
		target = 'updater/main',
		size = 3,
		digest_alg = 'sha256',
		digest = protocol.digest_hex('abc'),
	})
	assert_nil(ok)
	assert_eq(err, 'unsupported_digest_alg')

	ok, err = protocol.validate({
		type = 'xfer_commit',
		xfer_id = 'xfer-1',
		size = 3,
		digest_alg = protocol.DIGEST_ALG,
		digest = 'ABCDEF12',
	})
	assert_nil(ok)
	assert_eq(err, 'invalid_digest')
end


function tests.test_contract_constants_match_fabric_jsonl_v1()
	assert_eq(protocol.PROTO, 'fabric-jsonl/1')
	assert_eq(protocol.DIGEST_ALG, 'xxhash32')
	assert_eq(protocol.DEFAULT_CHUNK_SIZE, 2048)

	assert_eq(protocol.classify('hello'), 'session_control')
	assert_eq(protocol.classify('hello_ack'), 'session_control')
	assert_eq(protocol.classify('ping'), 'session_control')
	assert_eq(protocol.classify('pong'), 'session_control')

	assert_eq(protocol.classify('pub'), 'rpc')
	assert_eq(protocol.classify('unretain'), 'rpc')
	assert_eq(protocol.classify('call'), 'rpc')
	assert_eq(protocol.classify('reply'), 'rpc')

	assert_eq(protocol.classify('xfer_begin'), 'transfer_control')
	assert_eq(protocol.classify('xfer_ready'), 'transfer_control')
	assert_eq(protocol.classify('xfer_need'), 'transfer_control')
	assert_eq(protocol.classify('xfer_commit'), 'transfer_control')
	assert_eq(protocol.classify('xfer_done'), 'transfer_control')
	assert_eq(protocol.classify('xfer_abort'), 'transfer_control')
	assert_eq(protocol.classify('xfer_chunk'), 'transfer_bulk')
end

function tests.test_unversioned_hello_is_rejected()
	local ok, err = protocol.validate({
		type = 'hello',
		sid = 'sid-1',
		node = 'cm5',
	})

	assert_nil(ok)
	assert_eq(err, 'missing_proto')

	ok, err = protocol.validate({
		type = 'hello_ack',
		sid = 'sid-2',
		node = 'mcu',
	})

	assert_nil(ok)
	assert_eq(err, 'missing_proto')
end

function tests.test_legacy_checksum_field_is_rejected_on_begin_and_commit()
	local ok, err = protocol.validate({
		type = 'xfer_begin',
		xfer_id = 'x1',
		target = 'updater/main',
		size = 3,
		digest_alg = protocol.DIGEST_ALG,
		digest = protocol.digest_hex('abc'),
		checksum = 'legacy',
	})

	assert_nil(ok)
	assert_eq(err, 'unknown_frame_field: checksum')

	ok, err = protocol.validate({
		type = 'xfer_commit',
		xfer_id = 'x1',
		size = 3,
		digest_alg = protocol.DIGEST_ALG,
		digest = protocol.digest_hex('abc'),
		checksum = 'legacy',
	})

	assert_nil(ok)
	assert_eq(err, 'unknown_frame_field: checksum')
end

function tests.test_legacy_chunk_without_digest_is_rejected_on_decode()
	local line = '{"type":"xfer_chunk","xfer_id":"xfer-1","offset":0,"data":"YQ"}'
	local frame, err = protocol.decode_line(line)

	assert_nil(frame)
	assert_eq(err, 'missing_chunk_digest')
end

return tests
