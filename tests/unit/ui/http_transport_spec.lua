local cjson = require 'cjson.safe'
local http = require 'services.ui.transport.http'
local ui_fakes = require 'tests.support.ui_fakes'

local T = {}

local function make_svc()
	return { name = 'ui', obs_log = function() end }
end

function T.http_handler_routes_login_and_sets_session_cookie()
	local called = {}
	local app = {
		login = function(username, password)
			called.username = username
			called.password = password
			return { session_id = 'sess-1', user = { id = username } }, nil
		end,
	}
	local handler = http.build_handler(make_svc(), app, {
		spawn_ws_client = function() error('unexpected ws spawn') end,
		ws_opts = {},
	})
	local stream = ui_fakes.fake_http_stream({
		method = 'POST',
		path = '/api/login',
		body = cjson.encode({ username = 'alice', password = 'pw' }),
	})
	assert(handler(nil, stream) == nil)
	assert(called.username == 'alice')
	assert(called.password == 'pw')
	assert(stream:status() == '200')
	local body = stream:json()
	assert(body.ok == true)
	assert(body.data.session_id == 'sess-1')
	assert(tostring(stream:header('set-cookie')):match('devicecode_session=sess%-1'))
end

function T.http_handler_passes_session_to_config_routes_and_clears_cookie_on_logout()
	local seen = {}
	local app = {
		config_get = function(session_id, service)
			seen.get_sid = session_id
			seen.get_service = service
			return { rev = 2 }, nil
		end,
		config_set = function(session_id, service, data)
			seen.set_sid = session_id
			seen.set_service = service
			seen.set_data = data
			return { ok = true }, nil
		end,
		logout = function(session_id)
			seen.logout_sid = session_id
			return { ok = true }, nil
		end,
	}
	local handler = http.build_handler(make_svc(), app, {
		spawn_ws_client = function() error('unexpected ws spawn') end,
		ws_opts = {},
	})

	local s1 = ui_fakes.fake_http_stream({
		method = 'GET',
		path = '/api/config/net',
		headers = {
			[':method'] = 'GET',
			[':path'] = '/api/config/net',
			cookie = 'devicecode_session=sess-cookie',
		},
	})
	handler(nil, s1)
	assert(seen.get_sid == 'sess-cookie')
	assert(seen.get_service == 'net')
	assert(s1:status() == '200')

	local s2 = ui_fakes.fake_http_stream({
		method = 'POST',
		path = '/api/config/net',
		body = cjson.encode({ data = { answer = 42 } }),
		headers = {
			[':method'] = 'POST',
			[':path'] = '/api/config/net',
			['x-session-id'] = 'sess-header',
		},
	})
	handler(nil, s2)
	assert(seen.set_sid == 'sess-header')
	assert(seen.set_service == 'net')
	assert(seen.set_data.answer == 42)
	assert(s2:status() == '200')

	local s3 = ui_fakes.fake_http_stream({
		method = 'POST',
		path = '/api/logout',
		headers = {
			[':method'] = 'POST',
			[':path'] = '/api/logout',
			cookie = 'devicecode_session=sess-cookie',
		},
	})
	handler(nil, s3)
	assert(seen.logout_sid == 'sess-cookie')
	assert(s3:status() == '200')
	assert(tostring(s3:header('set-cookie')):match('Max%-Age=0'))
end

return T
