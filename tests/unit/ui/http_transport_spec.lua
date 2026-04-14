-- tests/unit/ui/http_transport_spec.lua

local cjson        = require 'cjson.safe'
local http_headers = require 'http.headers'

local transport    = require 'services.ui.http_transport'

local T = {}

local function make_req_headers(method, path, extra)
	local h = http_headers.new()
	h:append(':method', method)
	h:append(':path', path)
	if type(extra) == 'table' then
		for k, v in pairs(extra) do h:append(k, v) end
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

	function stream:get_headers() return self._req_headers end
	function stream:get_body_as_string() return self._req_body end

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
			calls[#calls + 1] = { username = username, password = password }
			return {
				session_id = 'sess-123',
				user = { id = 'admin', kind = 'user', roles = { 'admin' } },
				expires_at = 12345,
			}, nil
		end,
	}

	local handler = transport.build_handler(fake_svc(), api, {})
	local stream = new_stream(make_req_headers('POST', '/api/login'), cjson.encode({ username = 'admin', password = 'secret' }))
	handler({}, stream)

	assert(stream:response_status() == '200')
	assert(stream:response_header('set-cookie'):match('devicecode_session=sess%-123') ~= nil)
	local body = decode_json_body(stream)
	assert(body.ok == true)
	assert(body.data.session_id == 'sess-123')
	assert(#calls == 1)
end

function T.http_login_failure_returns_401()
	local api = { login = function() return nil, 'invalid credentials' end }
	local handler = transport.build_handler(fake_svc(), api, {})
	local stream = new_stream(make_req_headers('POST', '/api/login'), cjson.encode({ username = 'admin', password = 'wrong' }))
	handler({}, stream)
	assert(stream:response_status() == '401')
	assert(decode_json_body(stream).err == 'invalid credentials')
end

function T.http_session_uses_cookie()
	local calls = {}
	local api = {
		get_session = function(session_id)
			calls[#calls + 1] = session_id
			return { session_id = session_id, user = { id = 'admin', kind = 'user', roles = { 'admin' } } }, nil
		end,
	}
	local handler = transport.build_handler(fake_svc(), api, {})
	local stream = new_stream(make_req_headers('GET', '/api/session', { cookie = 'foo=bar; devicecode_session=sess-cookie; baz=qux' }))
	handler({}, stream)
	assert(stream:response_status() == '200')
	assert(decode_json_body(stream).data.session_id == 'sess-cookie')
	assert(calls[1] == 'sess-cookie')
end

function T.http_logout_clears_cookie_and_uses_401_for_bad_session()
	local calls = {}
	local api = {
		logout = function(session_id)
			calls[#calls + 1] = session_id
			if session_id == 'bad' then return nil, 'invalid or expired session' end
			return true, nil
		end,
	}
	local handler = transport.build_handler(fake_svc(), api, {})

	local ok_stream = new_stream(make_req_headers('POST', '/api/logout', { cookie = 'devicecode_session=sess-logout' }), '{}')
	handler({}, ok_stream)
	assert(ok_stream:response_status() == '200')
	assert(ok_stream:response_header('set-cookie'):match('Max%-Age=0') ~= nil)

	local bad_stream = new_stream(make_req_headers('POST', '/api/logout', { cookie = 'devicecode_session=bad' }), '{}')
	handler({}, bad_stream)
	assert(bad_stream:response_status() == '401')
	assert(calls[1] == 'sess-logout')
	assert(calls[2] == 'bad')
end

function T.http_config_get_uses_404_for_missing_and_200_for_present()
	local api = {
		config_get = function(_, service_name)
			if service_name == 'missing' then return nil, 'not found' end
			return { rev = 3, data = { schema = 'devicecode.net/2', answer = 42 } }, nil
		end,
	}
	local handler = transport.build_handler(fake_svc(), api, {})

	local ok_stream = new_stream(make_req_headers('GET', '/api/config/net', { cookie = 'devicecode_session=sess-net' }))
	handler({}, ok_stream)
	assert(ok_stream:response_status() == '200')
	assert(decode_json_body(ok_stream).data.data.answer == 42)

	local miss_stream = new_stream(make_req_headers('GET', '/api/config/missing', { cookie = 'devicecode_session=sess-net' }))
	handler({}, miss_stream)
	assert(miss_stream:response_status() == '404')
end

function T.http_config_post_returns_400_on_bad_body_and_401_on_missing_session()
	local api = {
		config_set = function(session_id, service_name, data)
			if session_id == nil then return nil, 'missing session' end
			if service_name == 'net' and type(data) ~= 'table' then return nil, 'data must be a plain table' end
			return { ok = true, persisted = false }, nil
		end,
	}
	local handler = transport.build_handler(fake_svc(), api, {})

	local bad_json = new_stream(make_req_headers('POST', '/api/config/net', { cookie = 'devicecode_session=sess-net' }), '{')
	handler({}, bad_json)
	assert(bad_json:response_status() == '400')

	local no_session = new_stream(make_req_headers('POST', '/api/config/net'), cjson.encode({ data = { schema = 'x' } }))
	handler({}, no_session)
	assert(no_session:response_status() == '401')
end

function T.http_service_status_capabilities_and_fabric_routes_use_expected_statuses()
	local api = {
		service_status = function(_, service_name)
			if service_name == 'missing' then return nil, 'not found' end
			return { state = 'running', ts = 123.0 }, nil
		end,
		capability_snapshot = function(session_id)
			if session_id == nil then return nil, 'missing session' end
			return { capabilities = {}, devices = {}, services = { announce = {}, status = {} } }, nil
		end,
		fabric_status = function() return { main = { status = 'running' }, links = {} }, nil end,
		fabric_link_status = function(_, link_id)
			if link_id == 'missing' then return nil, 'not found' end
			return { link = { status = 'ready' }, transfer = nil }, nil
		end,
	}
	local handler = transport.build_handler(fake_svc(), api, {})

	local svc_ok = new_stream(make_req_headers('GET', '/api/service/net/status', { cookie = 'devicecode_session=sess' }))
	handler({}, svc_ok)
	assert(svc_ok:response_status() == '200')

	local svc_missing = new_stream(make_req_headers('GET', '/api/service/missing/status', { cookie = 'devicecode_session=sess' }))
	handler({}, svc_missing)
	assert(svc_missing:response_status() == '404')

	local caps_no_session = new_stream(make_req_headers('GET', '/api/capabilities'))
	handler({}, caps_no_session)
	assert(caps_no_session:response_status() == '401')

	local fabric_ok = new_stream(make_req_headers('GET', '/api/fabric', { cookie = 'devicecode_session=sess' }))
	handler({}, fabric_ok)
	assert(fabric_ok:response_status() == '200')

	local link_missing = new_stream(make_req_headers('GET', '/api/fabric/link/missing', { cookie = 'devicecode_session=sess' }))
	handler({}, link_missing)
	assert(link_missing:response_status() == '404')
end

function T.http_rpc_route_maps_timeout_to_504_and_invalid_payload_to_400()
	local api = {
		rpc_call = function(_, service_name, method_name, payload, timeout)
			if payload == nil then return nil, 'payload must be a table or nil' end
			if timeout == 0.5 then return nil, 'timeout' end
			return { ok = true, method = method_name }, nil
		end,
	}
	local handler = transport.build_handler(fake_svc(), api, {})

	local timeout_stream = new_stream(make_req_headers('POST', '/api/rpc/hal/dump', { ['x-session-id'] = 'sess-rpc' }), cjson.encode({ payload = { x = 1 }, timeout = 0.5 }))
	handler({}, timeout_stream)
	assert(timeout_stream:response_status() == '504')

	local bad_json = new_stream(make_req_headers('POST', '/api/rpc/hal/dump', { ['x-session-id'] = 'sess-rpc' }), '{')
	handler({}, bad_json)
	assert(bad_json:response_status() == '400')
end

function T.http_fabric_transfer_routes_cover_send_status_abort_and_status_mapping()
	local api = {
		firmware_send = function(_, link_id, source, meta)
			assert(link_id == 'uart0')
			assert(type(source) == 'table')
			assert(type(source.open) == 'function')
			assert(meta.kind == 'firmware.rp2350')
			return { ok = true, transfer_id = 'tx-1' }, nil
		end,
		transfer_status = function(_, transfer_id)
			if transfer_id == 'gone' then return nil, 'unknown transfer' end
			return { ok = true, transfer = { id = transfer_id, status = 'sending' } }, nil
		end,
		transfer_abort = function(_, transfer_id)
			if transfer_id == 'busy' then return nil, 'busy' end
			return { ok = true }, nil
		end,
	}
	local handler = transport.build_handler(fake_svc(), api, {})

	local fw = new_stream(make_req_headers('POST', '/api/fabric/firmware/uart0', { cookie = 'devicecode_session=sess', ['x-filename'] = 'fw.bin' }), 'abcd')
	handler({}, fw)
	assert(fw:response_status() == '200')
	assert(decode_json_body(fw).data.transfer_id == 'tx-1')

	local status_ok = new_stream(make_req_headers('GET', '/api/fabric/transfer/tx-1', { cookie = 'devicecode_session=sess' }))
	handler({}, status_ok)
	assert(status_ok:response_status() == '200')

	local status_missing = new_stream(make_req_headers('GET', '/api/fabric/transfer/gone', { cookie = 'devicecode_session=sess' }))
	handler({}, status_missing)
	assert(status_missing:response_status() == '404')

	local abort_busy = new_stream(make_req_headers('POST', '/api/fabric/transfer/busy/abort', { cookie = 'devicecode_session=sess' }), '{}')
	handler({}, abort_busy)
	assert(abort_busy:response_status() == '503')
end

function T.http_health_route_returns_200_and_unknown_api_route_returns_404()
	local api = { health = function() return { service = 'ui', sessions = 2, now = 123.0 }, nil end }
	local handler = transport.build_handler(fake_svc(), api, {})

	local health = new_stream(make_req_headers('GET', '/api/health'))
	handler({}, health)
	assert(health:response_status() == '200')
	assert(decode_json_body(health).data.service == 'ui')

	local missing = new_stream(make_req_headers('GET', '/api/nope'))
	handler({}, missing)
	assert(missing:response_status() == '404')
	assert(missing:response_body():match('not found') ~= nil)
end

return T
