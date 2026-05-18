local policy = require 'services.http.policy'

local M = {}

local function eq(a, b, msg)
	if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end

local function ok(v, msg)
	if not v then error(msg or 'assertion failed', 2) end
	return v
end

function M.test_locality_requires_local_origin_without_fabric_peer_fields()
	ok(policy.is_local_origin({ kind = 'local' }))
	eq(policy.require_local_origin({ kind = 'fabric', peer_node = 'n1' }), nil)
	local allowed, err = policy.require_local_origin({ kind = 'local', link_id = 'l1' })
	eq(allowed, nil)
	eq(err, 'not_local')
end


function M.test_validate_uri_uses_lua_http_authority_boundary()
	local parsed = ok(policy.validate_uri('http://example.test:8080/path?q=1'))
	eq(parsed.scheme, 'http')
	eq(parsed.authority, 'example.test:8080')
	eq(parsed.host, 'example.test')
	eq(parsed.port, 8080)
	local ws = ok(policy.validate_uri('wss://example.test/ws'))
	eq(ws.scheme, 'wss')
	eq(ws.host, 'example.test')
	local plain_ws = ok(policy.validate_uri('ws://example.test/ws'))
	eq(plain_ws.scheme, 'ws')
	eq(plain_ws.host, 'example.test')
end

function M.test_validate_uri_rejects_missing_authority_via_lua_http_boundary()
	local parsed, err = policy.validate_uri('http:///missing-host')
	eq(parsed, nil)
	eq(err, 'invalid_args')
end

function M.test_validate_exchange_rejects_raw_body_bytes_over_control_plane()
	local checked = ok(policy.validate_exchange_args { uri = 'http://example.test/', method = 'GET' })
	eq(checked.method, 'GET')
	local bad, err = policy.validate_exchange_args { uri = 'http://example.test/', method = 'POST', body = 'bytes' }
	eq(bad, nil)
	eq(err, 'invalid_args')
	bad, err = policy.validate_exchange_args { uri = 'http://example.test/', method = 'POST', data = 'bytes' }
	eq(bad, nil)
	eq(err, 'invalid_args')
end

function M.test_validate_exchange_accepts_body_object_capabilities_and_rejects_remote_reference_tables()
	local source = { read_chunk_op = function () end, terminate = function () return true end }
	local sink = { write_chunk_op = function () end, terminate = function () return true end }
	local checked = ok(policy.validate_exchange_args {
		uri = 'http://example.test/',
		method = 'POST',
		body_source = source,
		response_sink = sink,
	})
	eq(checked.body_source, source)
	eq(checked.response_sink, sink)

	local bad, err = policy.validate_exchange_args {
		uri = 'http://example.test/',
		method = 'POST',
		body_source = { kind = 'remote-ref' },
	}
	eq(bad, nil)
	eq(err, 'invalid_args')
	bad, err = policy.validate_exchange_args { uri = 'http://example.test/', method = 'POST', source = source }
	eq(bad, nil)
	eq(err, 'invalid_args')
end

function M.test_validate_exchange_accepts_tolerant_parser_and_timeout()
	local checked = ok(policy.validate_exchange_args {
		uri = 'http://example.test/',
		method = 'GET',
		response_parser = 'tolerant-http1',
		timeout_s = 10,
	})
	eq(checked.response_parser, 'tolerant-http1')
	eq(checked.timeout_s, 10)

	local bad, err = policy.validate_exchange_args { uri = 'http://example.test/', response_parser = 'raw-socket' }
	eq(bad, nil)
	eq(err, 'invalid_args')
	bad, err = policy.validate_exchange_args { uri = 'http://example.test/', timeout_s = -1 }
	eq(bad, nil)
	eq(err, 'invalid_args')

	bad, err = policy.validate_exchange_args { uri = 'https://example.test/', response_parser = 'tolerant-http1' }
	eq(bad, nil)
	eq(err, 'unsupported_scheme')
end

function M.test_validate_listen_defaults_loopback_ephemeral_port()
	local args = ok(policy.validate_listen_args {})
	eq(args.host, '127.0.0.1')
	eq(args.port, 0)
	eq(args.tls, false)
end

function M.test_public_payload_validation_rejects_backend_objects()
	local listen, lerr = policy.validate_listen_args { host = '127.0.0.1', port = 0, backend_timeout = 2 }
	eq(listen, nil)
	eq(lerr, 'invalid_args')
	local exchange, eerr = policy.validate_exchange_args { uri = 'http://example.test/', request_module = {} }
	eq(exchange, nil)
	eq(eerr, 'invalid_args')
	local ws, werr = policy.validate_connect_ws_args { uri = 'ws://example.test/', websocket_module = {} }
	eq(ws, nil)
	eq(werr, 'invalid_args')
end

return M
