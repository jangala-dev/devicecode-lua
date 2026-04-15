-- tests/ui_http_transport_spec.lua

local cjson        = require 'cjson.safe'
local http_headers = require 'http.headers'

local transport    = require 'services.ui.http_transport'

local T = {}

local function make_req_headers(method, path, extra)
	local h = http_headers.new()
	h:append(':method', method)
	h:append(':path', path)
	if type(extra) == 'table' then
		for k, v in pairs(extra) do
			h:append(k, v)
		end
	end
	return h
end

local function new_stream(req_headers, body)
	local stream = {
		_req_headers = req_headers,
		_req_body    = body or '',
		_res_headers = nil,
		_res_chunks  = {},
		_res_done    = false,
		state        = 'open',
	}

	function stream:get_headers()
		return self._req_headers
	end

	function stream:get_body_as_string()
		return self._req_body
	end

	function stream:write_headers(headers, end_stream)
		self._res_headers = headers
		self._res_headers_end_stream = end_stream
		if end_stream then
			self._res_done = true
			self.state = 'closed'
		end
		return true
	end

	function stream:write_chunk(chunk, end_stream)
		self._res_chunks[#self._res_chunks + 1] = chunk or ''
		if end_stream then
			self._res_done = true
			self.state = 'closed'
		end
		return true
	end

	function stream:response_status()
		return self._res_headers and self._res_headers:get(':status') or nil
	end

	function stream:response_header(name)
		return self._res_headers and self._res_headers:get(name) or nil
	end

	function stream:response_body()
		return table.concat(self._res_chunks)
	end

	return stream
end

local function decode_json_body(stream)
	local body = stream:response_body()
	local obj, err = cjson.decode(body)
	assert(obj ~= nil, tostring(err))
	return obj
end

local function fake_svc()
	return {
		name = 'ui',
		obs_log = function(...) end,
	}
end

function T.http_login_sets_cookie_and_returns_session()
	local calls = {}

	local api = {
		login = function(username, password)
			calls[#calls + 1] = {
				op       = 'login',
				username = username,
				password = password,
			}
			return {
				session_id = 'sess-123',
				user = {
					id    = 'admin',
					kind  = 'user',
					roles = { 'admin' },
				},
				expires_at = 12345,
			}, nil
		end,
	}

	local handler = transport.build_handler(fake_svc(), api, {})
	local stream = new_stream(
		make_req_headers('POST', '/api/login'),
		cjson.encode({
			username = 'admin',
			password = 'secret',
		})
	)

	handler({}, stream)

	assert(stream:response_status() == '200')
	assert(type(stream:response_header('set-cookie')) == 'string')
	assert(stream:response_header('set-cookie'):match('devicecode_session=sess%-123') ~= nil)

	local body = decode_json_body(stream)
	assert(body.ok == true)
	assert(type(body.data) == 'table')
	assert(body.data.session_id == 'sess-123')

	assert(#calls == 1)
	assert(calls[1].username == 'admin')
	assert(calls[1].password == 'secret')
end

function T.http_login_failure_returns_401()
	local api = {
		login = function(username, password)
			return nil, 'invalid credentials'
		end,
	}

	local handler = transport.build_handler(fake_svc(), api, {})
	local stream = new_stream(
		make_req_headers('POST', '/api/login'),
		cjson.encode({
			username = 'admin',
			password = 'wrong',
		})
	)

	handler({}, stream)

	assert(stream:response_status() == '401')

	local body = decode_json_body(stream)
	assert(body.ok == false)
	assert(body.err == 'invalid credentials')
end

function T.http_session_uses_cookie()
	local calls = {}

	local api = {
		get_session = function(session_id)
			calls[#calls + 1] = {
				op = 'get_session',
				session_id = session_id,
			}
			return {
				session_id = session_id,
				user = {
					id    = 'admin',
					kind  = 'user',
					roles = { 'admin' },
				},
			}, nil
		end,
	}

	local handler = transport.build_handler(fake_svc(), api, {})
	local stream = new_stream(
		make_req_headers('GET', '/api/session', {
			cookie = 'foo=bar; devicecode_session=sess-cookie; baz=qux',
		})
	)

	handler({}, stream)

	assert(stream:response_status() == '200')

	local body = decode_json_body(stream)
	assert(body.ok == true)
	assert(body.data.session_id == 'sess-cookie')

	assert(#calls == 1)
	assert(calls[1].session_id == 'sess-cookie')
end

function T.http_logout_clears_cookie()
	local calls = {}

	local api = {
		logout = function(session_id)
			calls[#calls + 1] = {
				op = 'logout',
				session_id = session_id,
			}
			return true, nil
		end,
	}

	local handler = transport.build_handler(fake_svc(), api, {})
	local stream = new_stream(
		make_req_headers('POST', '/api/logout', {
			cookie = 'devicecode_session=sess-logout',
		}),
		'{}'
	)

	handler({}, stream)

	assert(stream:response_status() == '200')
	assert(type(stream:response_header('set-cookie')) == 'string')
	assert(stream:response_header('set-cookie'):match('Max%-Age=0') ~= nil)

	local body = decode_json_body(stream)
	assert(body.ok == true)

	assert(#calls == 1)
	assert(calls[1].session_id == 'sess-logout')
end

function T.http_config_route_uses_cookie_session()
	local calls = {}

	local api = {
		config_set = function(session_id, service_name, data)
			calls[#calls + 1] = {
				op           = 'config_set',
				session_id   = session_id,
				service_name = service_name,
				data         = data,
			}
			return {
				ok = true,
				persisted = false,
			}, nil
		end,
	}

	local handler = transport.build_handler(fake_svc(), api, {})
	local stream = new_stream(
		make_req_headers('POST', '/api/config/net', {
			cookie = 'devicecode_session=sess-net',
		}),
		cjson.encode({
			data = {
				schema = 'devicecode.net/1',
				answer = 42,
			},
		})
	)

	handler({}, stream)

	assert(stream:response_status() == '200')

	local body = decode_json_body(stream)
	assert(body.ok == true)
	assert(type(body.data) == 'table')
	assert(body.data.ok == true)
	assert(body.data.persisted == false)

	assert(#calls == 1)
	assert(calls[1].session_id == 'sess-net')
	assert(calls[1].service_name == 'net')
	assert(type(calls[1].data) == 'table')
	assert(calls[1].data.answer == 42)
end

function T.http_rpc_route_prefers_cookie_then_body()
	local calls = {}

	local api = {
		rpc_call = function(session_id, service_name, method_name, payload, timeout)
			calls[#calls + 1] = {
				op           = 'rpc_call',
				session_id   = session_id,
				service_name = service_name,
				method_name  = method_name,
				payload      = payload,
				timeout      = timeout,
			}
			return {
				ok = true,
				method = method_name,
			}, nil
		end,
	}

	local handler = transport.build_handler(fake_svc(), api, {})
	local stream = new_stream(
		make_req_headers('POST', '/api/rpc/hal/dump', {
			['x-session-id'] = 'sess-rpc',
		}),
		cjson.encode({
			payload = {
				packages = { 'network', 'firewall' },
			},
			timeout = 0.5,
		})
	)

	handler({}, stream)

	assert(stream:response_status() == '200')

	local body = decode_json_body(stream)
	assert(body.ok == true)
	assert(type(body.data) == 'table')
	assert(body.data.ok == true)
	assert(body.data.method == 'dump')

	assert(#calls == 1)
	assert(calls[1].session_id == 'sess-rpc')
	assert(calls[1].service_name == 'hal')
	assert(calls[1].method_name == 'dump')
	assert(type(calls[1].payload) == 'table')
	assert(type(calls[1].payload.packages) == 'table')
	assert(calls[1].payload.packages[1] == 'network')
	assert(calls[1].timeout == 0.5)
end

function T.http_health_route_returns_200()
	local api = {
		health = function()
			return {
				service  = 'ui',
				sessions = 2,
				now      = 123.0,
			}, nil
		end,
	}

	local handler = transport.build_handler(fake_svc(), api, {})
	local stream = new_stream(
		make_req_headers('GET', '/api/health')
	)

	handler({}, stream)

	assert(stream:response_status() == '200')

	local body = decode_json_body(stream)
	assert(body.ok == true)
	assert(type(body.data) == 'table')
	assert(body.data.service == 'ui')
	assert(body.data.sessions == 2)
end

function T.http_unknown_api_route_returns_404()
	local api = {}

	local handler = transport.build_handler(fake_svc(), api, {})
	local stream = new_stream(
		make_req_headers('GET', '/api/nope')
	)

	handler({}, stream)

	assert(stream:response_status() == '404')
	assert(stream:response_body():match('not found') ~= nil)
end

return T
