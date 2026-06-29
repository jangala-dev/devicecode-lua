local fibers = require 'fibers'
local op = require 'fibers.op'
local legacy = require 'services.http.transport.legacy_http1_close'

local M = {}

local function eq(a, b, msg)
	if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end
local function ok(v, msg) if not v then error(msg or 'assertion failed', 2) end return v end

function M.test_parse_response_requires_status_line_and_keeps_body_bytes()
	local headers, stream = legacy._test.parse_response('HTTP/1.1 200 OK\r\nServer: Hydra/0.1.8\r\nConnection: close\r\n\r\n{"data":{"ok":true}}')
	ok(headers)
	eq(headers:get(':status'), '200')
	eq(headers:get('server'), 'Hydra/0.1.8')
	eq(stream:get_body_as_string(), '{"data":{"ok":true}}')

	local bad, _, err = legacy._test.parse_response('not http before json {"data":{"ok":true}}')
	eq(bad, nil)
	eq(err, 'no_header_separator')
end

function M.test_render_request_uses_http10_connection_close_and_content_length()
	local chunks = { 'abc' }
	local req = legacy._test.render_request({
		method = 'POST',
		_uri = { path = '/cgi/set.cgi?cmd=home_loginAuth', authority = '192.168.1.1' },
		headers = { ['content-type'] = 'application/x-www-form-urlencoded' },
	}, 'abc')
	ok(req:find('POST /cgi/set.cgi?cmd=home_loginAuth HTTP/1.0\r\n', 1, true))
	ok(req:find('Host: 192.168.1.1\r\n', 1, true))
	ok(req:find('Connection: close\r\n', 1, true))
	ok(req:find('Content-Length: 3\r\n', 1, true))
	ok(req:find('\r\n\r\nabc', 1, true))
end

function M.test_read_response_bounded_stops_at_content_length_without_eof()
	fibers.run(function ()
		local reads = {
			'HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: keep-alive\r\n\r\n{',
			'"x":1}',
		}
		local stream = {
			read_some_op = function (_, _want)
				local chunk = table.remove(reads, 1)
				if chunk == nil then return op.always(nil, 'unexpected_extra_read') end
				return op.always(chunk, nil)
			end,
		}
		local headers, body_stream, err = legacy._test.read_response_bounded(stream, 1024, 'GET')
		ok(headers, err)
		eq(headers:get(':status'), '200')
		eq(body_stream:get_body_as_string(), '{"x":1}')
		eq(#reads, 0)
	end)
end


function M.test_render_request_preserves_query_from_original_uri()
	local request = ok(legacy._test.render_request({
		method = 'GET',
		_uri = {
			uri = 'http://192.168.1.1/cgi/get.cgi?cmd=panel_info&dummy=123',
			scheme = 'http',
			host = '192.168.1.1',
			port = 80,
			path = '/cgi/get.cgi',
			authority = '192.168.1.1',
		},
	}))
	ok(request:find('GET /cgi/get.cgi?cmd=panel_info&dummy=123 HTTP/1.0', 1, true))
end


function M.test_parse_response_rejects_chunked_transfer_encoding()
	local headers, stream, err = legacy._test.parse_response(
		'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n7\r\n{"x":1}\r\n0\r\n\r\n'
	)
	eq(headers, nil)
	eq(stream, nil)
	eq(err, 'unsupported_transfer_encoding')
end

function M.test_read_response_bounded_rejects_oversize_headers()
	fibers.run(function ()
		local stream = {
			read_some_op = function () return op.always('HTTP/1.1 200 OK\r\nX-Long: abcdef\r\n', nil) end,
		}
		local headers, body_stream, err = legacy._test.read_response_bounded(stream, 16, 'GET')
		eq(headers, nil)
		eq(body_stream, nil)
		eq(err, 'response_too_large')
	end)
end

return M
