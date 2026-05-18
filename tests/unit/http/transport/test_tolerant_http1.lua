local fibers = require 'fibers'
local tolerant = require 'services.http.transport.tolerant_http1'

local M = {}

local function eq(a, b, msg)
	if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end

local function ok(v, msg)
	if not v then error(msg or 'assertion failed', 2) end
	return v
end

function M.test_parse_response_accepts_simple_http1_body()
	local headers, stream = tolerant._test.parse_response(
		'HTTP/1.1 200 OK\r\nServer: Hydra/0.1.8\r\nConnection: close\r\n\r\n{"data":{"ok":true}}'
	)
	ok(headers)
	eq(headers:get(':status'), '200')
	eq(headers:get('server'), 'Hydra/0.1.8')
	eq(stream:get_body_as_string(), '{"data":{"ok":true}}')
end

function M.test_parse_response_accepts_body_when_status_line_is_missing()
	local headers, stream = tolerant._test.parse_response('not http before json {"data":{"ok":true}}')
	ok(headers)
	eq(headers:get(':status'), '200')
	eq(stream:get_body_as_string(), '{"data":{"ok":true}}')
end

function M.test_build_request_adds_http10_host_and_single_content_length()
	local chunks = { 'abc' }
	local request = ok(tolerant._test.build_request({
		method = 'POST',
		_uri = { path = '/cgi/set.cgi?cmd=home_loginAuth', authority = '172.28.100.9' },
		headers = { ['Content-Type'] = 'application/x-www-form-urlencoded', ['Content-Length'] = '3' },
		_request_body = function () return table.remove(chunks, 1) end,
	}))
	ok(request:find('POST /cgi/set.cgi?cmd=home_loginAuth HTTP/1.0\r\n', 1, true))
	ok(request:find('Host: 172.28.100.9\r\n', 1, true))
	ok(request:find('\r\n\r\nabc', 1, true))
	local _, count = request:gsub('Content%-Length:', '')
	eq(count, 1)
end

function M.test_open_exchange_uses_socket_module_inside_http_transport()
	fibers.run(function ()
		local written
		local socket_mod = {
			connect = function (host, port)
				eq(host, '172.28.100.9')
				eq(port, 80)
				local reads = {
					'HTTP/1.0 202 Accepted\r\n\r\n{"data":{"ok":true}}',
					nil,
				}
				return {
					settimeout = function (_, timeout) eq(timeout, 10) end,
					setmode = function (_, rmode, wmode) eq(rmode, 'b'); eq(wmode, 'b') end,
					write = function (_, data) written = data; return true end,
					flush = function () return true end,
					read = function ()
						local next_chunk = table.remove(reads, 1)
						if next_chunk == nil then return nil, 'eof' end
						return next_chunk
					end,
					close = function () return true end,
				}
			end,
		}
		local driver = {
			run_op = function (_, _, fn) return fibers.always(fn()) end,
			}
			local headers, stream = fibers.perform(tolerant.open_exchange_op(driver, {
				method = 'GET',
				response_parser = 'tolerant-http1',
				timeout_s = 10,
				_uri = {
					scheme = 'http',
					host = '172.28.100.9',
					port = 80,
					path = '/cgi/get.cgi?cmd=panel_info',
					authority = '172.28.100.9',
				},
			}, { socket_module = socket_mod }))
		ok(headers)
		eq(headers:get(':status'), '202')
		eq(stream:get_body_as_string(), '{"data":{"ok":true}}')
		ok(written:find('GET /cgi/get.cgi?cmd=panel_info HTTP/1.0', 1, true))
	end)
end

function M.test_open_exchange_rejects_https_for_tolerant_socket_transport()
	fibers.run(function ()
		local driver = {
			run_op = function (_, _, fn) return fibers.always(fn()) end,
		}
		local headers, err = fibers.perform(tolerant.open_exchange_op(driver, {
			_uri = { scheme = 'https', host = 'example.test', port = 443, path = '/', authority = 'example.test' },
		}, { socket_module = { connect = function () error('connect should not run', 0) end } }))
		eq(headers, nil)
		eq(err, 'unsupported_scheme')
	end)
end

return M
