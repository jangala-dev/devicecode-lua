-- services/ui/transport/http.lua
--
-- HTTP transport for the UI service.
--
-- Responsibilities:
--   * route HTTP API requests onto the application façade
--   * serve static assets for the local UI
--   * upgrade /ws requests to the websocket transport
--
-- This file is a transport boundary only; it does not contain business logic.

local safe         = require 'coxpcall'
local fibers       = require 'fibers'
local file         = require 'fibers.io.file'
local http_server  = require 'http.server'
local http_headers = require 'http.headers'
local http_util    = require 'http.util'
local cjson        = require 'cjson.safe'

local cq_bridge = require 'services.ui.cqueues_bridge'
local errors    = require 'services.ui.errors'
local ws_client = require 'services.ui.transport.ws_client'

local M = {}

local function split_path(path)
	local out = {}
	for seg in tostring(path or ''):gmatch('[^/]+') do
		out[#out + 1] = seg
	end
	return out
end

local function starts_with(s, prefix)
	return type(s) == 'string' and s:sub(1, #prefix) == prefix
end

local function path_ext(path)
	return tostring(path):match('(%.[%w_%-]+)$')
end

local MIME = {
	['.html']  = 'text/html; charset=utf-8',
	['.js']    = 'application/javascript',
	['.css']   = 'text/css',
	['.json']  = 'application/json',
	['.svg']   = 'image/svg+xml',
	['.png']   = 'image/png',
	['.jpg']   = 'image/jpeg',
	['.jpeg']  = 'image/jpeg',
	['.ico']   = 'image/x-icon',
	['.webp']  = 'image/webp',
	['.woff']  = 'font/woff',
	['.woff2'] = 'font/woff2',
	['.ttf']   = 'font/ttf',
	['.map']   = 'application/json',
}

local function mime_for_path(path)
	return MIME[path_ext(path or '')] or 'application/octet-stream'
end

local function cookie_value(cookie_header, name)
	if type(cookie_header) ~= 'string' or cookie_header == '' then
		return nil
	end
	for part in cookie_header:gmatch('[^;]+') do
		local k, v = part:match('^%s*([^=]+)%s*=%s*(.-)%s*$')
		if k == name then
			return v
		end
	end
	return nil
end

local function session_id_from_headers(req_headers)
	local cookie = req_headers:get('cookie')
	local sid = cookie_value(cookie, 'devicecode_session')
	if sid and sid ~= '' then return sid end

	local hdr = req_headers:get('x-session-id')
	if hdr and hdr ~= '' then return hdr end

	return nil
end

local function response_headers(status, content_type, extra)
	local h = http_headers.new()
	h:append(':status', tostring(status))
	if content_type then
		h:append('content-type', content_type)
	end
	if type(extra) == 'table' then
		for i = 1, #extra do
			local kv = extra[i]
			if type(kv) == 'table' and kv[1] and kv[2] then
				h:append(kv[1], kv[2])
			end
		end
	end
	return h
end

local function write_json(stream, status, payload, extra_headers)
	local body = cjson.encode(payload or {}) or '{"ok":false,"err":"json_encode_failed"}'
	local h = response_headers(status, 'application/json; charset=utf-8', extra_headers)
	assert(stream:write_headers(h, false))
	assert(stream:write_chunk(body, true))
end

local function write_text(stream, status, text, extra_headers)
	local h = response_headers(status, 'text/plain; charset=utf-8', extra_headers)
	assert(stream:write_headers(h, false))
	assert(stream:write_chunk(tostring(text or ''), true))
end

local function write_api_result(stream, out, err, ok_status, extra_headers)
	if out ~= nil then
		write_json(stream, ok_status or 200, { ok = true, data = out }, extra_headers)
		return true
	end

	local status, payload = errors.to_response(err)
	write_json(stream, status, payload, extra_headers)
	return true
end

local function read_body_string(stream)
	if type(stream.get_body_as_string) == 'function' then
		local ok, body = safe.pcall(function()
			return stream:get_body_as_string()
		end)
		if ok then
			return body or ''
		end
		return nil, body
	end
	return nil, 'http stream does not support get_body_as_string()'
end

local function read_json_body(stream)
	local body, err = read_body_string(stream)
	if body == nil then
		return nil, errors.bad_request('body_read_failed: ' .. tostring(err))
	end
	if body == '' then
		return {}, nil
	end

	local obj, jerr = cjson.decode(body)
	if obj == nil or type(obj) ~= 'table' then
		return nil, errors.bad_request('json_decode_failed: ' .. tostring(jerr))
	end
	return obj, nil
end

local function set_session_cookie_headers(session_id)
	return {
		{ 'set-cookie', ('devicecode_session=%s; Path=/; HttpOnly; SameSite=Strict'):format(tostring(session_id)) },
	}
end

local function clear_session_cookie_headers()
	return {
		{ 'set-cookie', 'devicecode_session=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict' },
	}
end

local function safe_segment(seg)
	return type(seg) == 'string'
		and seg ~= ''
		and seg ~= '.'
		and seg ~= '..'
		and not seg:find('[\\%z]')
end

local function static_path(www_root, req_path)
	if type(www_root) ~= 'string' or www_root == '' then
		return nil
	end

	local p = tostring(req_path or '/')
	if p == '/' or p == '' then
		return www_root .. '/index.html'
	end

	local parts = split_path(p)
	for i = 1, #parts do
		if not safe_segment(parts[i]) then
			return nil
		end
	end

	local candidate = www_root .. '/' .. table.concat(parts, '/')
	if path_ext(candidate) then
		return candidate
	end
	return www_root .. '/index.html'
end

local function serve_static(svc, stream, req_method, req_path, www_root)
	local path = static_path(www_root, req_path)
	if not path then
		write_text(stream, 404, 'not found\n')
		return true
	end

	local s = file.open(path, 'r')
	if not s then
		write_text(stream, 404, 'not found\n')
		return true
	end

	fibers.current_scope():finally(function()
		s:close()
	end)

	local h = response_headers(200, mime_for_path(path))
	assert(stream:write_headers(h, req_method == 'HEAD'))

	if req_method ~= 'HEAD' then
		while true do
			local chunk, rerr = s:read_some(16384)
			if rerr ~= nil then
				error('static_read_failed: ' .. tostring(rerr), 0)
			end
			if chunk == nil then
				break
			end
			assert(stream:write_chunk(chunk, false))
		end
		assert(stream:write_chunk('', true))
	end

	svc:obs_log('info', { what = 'http_static', path = req_path })
	return true
end

local function method_not_allowed(stream)
	write_text(stream, 405, 'method not allowed\n')
	return true
end

local function handle_auth_api(app, stream, req_method, req_path, sid, body_or_reply)
	if req_path == '/api/login' then
		if req_method ~= 'POST' then return method_not_allowed(stream), true end
		local body = body_or_reply()
		if not body then return true, true end

		local out, err = app.login(body.username, body.password)
		if not out then
			return write_api_result(stream, nil, err), true
		end

		return write_api_result(stream, out, nil, 200, set_session_cookie_headers(out.session_id)), true
	end

	if req_path == '/api/logout' then
		if req_method ~= 'POST' then return method_not_allowed(stream), true end

		local out, err = app.logout(sid)
		if out ~= nil then
			return write_json(stream, 200, { ok = true, data = out }, clear_session_cookie_headers()), true
		end

		local status, payload = errors.to_response(err)
		return write_json(stream, status, payload, clear_session_cookie_headers()), true
	end

	if req_path == '/api/session' then
		if req_method ~= 'GET' then return method_not_allowed(stream), true end
		return write_api_result(stream, app.get_session(sid)), true
	end

	if req_path == '/api/health' then
		if req_method ~= 'GET' then return method_not_allowed(stream), true end
		return write_api_result(stream, app.health()), true
	end

	return false
end

local function handle_query_api(app, stream, req_method, req_path, sid, body_or_reply)
	if req_path == '/api/services' then
		if req_method ~= 'GET' then return method_not_allowed(stream), true end
		return write_api_result(stream, app.services_snapshot(sid)), true
	end

	if req_path == '/api/capabilities' then
		if req_method ~= 'GET' then return method_not_allowed(stream), true end
		return write_api_result(stream, app.capability_snapshot(sid)), true
	end

	if req_path == '/api/model/exact' then
		if req_method ~= 'POST' then return method_not_allowed(stream), true end
		local body = body_or_reply()
		if not body then return true, true end
		return write_api_result(stream, app.model_exact(sid, body.topic)), true
	end

	if req_path == '/api/model/snapshot' then
		if req_method ~= 'POST' then return method_not_allowed(stream), true end
		local body = body_or_reply()
		if not body then return true, true end
		return write_api_result(stream, app.model_snapshot(sid, body.pattern)), true
	end

	return false
end

local function handle_config_api(app, stream, req_method, parts, sid, body_or_reply)
	if #parts == 3 and parts[1] == 'api' and parts[2] == 'config' then
		if req_method == 'GET' then
			return write_api_result(stream, app.config_get(sid, parts[3])), true
		elseif req_method == 'POST' then
			local body = body_or_reply()
			if not body then return true, true end
			return write_api_result(stream, app.config_set(sid, parts[3], body.data)), true
		end
		return method_not_allowed(stream), true
	end

	if #parts == 4 and parts[1] == 'api' and parts[2] == 'service' and parts[4] == 'status' then
		if req_method ~= 'GET' then return method_not_allowed(stream), true end
		return write_api_result(stream, app.service_status(sid, parts[3])), true
	end

	return false
end

local function handle_fabric_api(app, stream, req_method, req_path, parts, sid)
	if req_path == '/api/fabric' then
		if req_method ~= 'GET' then return method_not_allowed(stream), true end
		return write_api_result(stream, app.fabric_status(sid)), true
	end

	if #parts == 4 and parts[1] == 'api' and parts[2] == 'fabric' and parts[3] == 'link' then
		if req_method ~= 'GET' then return method_not_allowed(stream), true end
		return write_api_result(stream, app.fabric_link_status(sid, parts[4])), true
	end

	return false
end

local function handle_update_api(app, stream, req_method, req_path, parts, sid, req_headers, body_or_reply)
	if req_path == '/api/update/jobs' then
		if req_method == 'GET' then
			return write_api_result(stream, app.update_job_list(sid)), true
		elseif req_method == 'POST' then
			local body = body_or_reply()
			if not body then return true, true end
			return write_api_result(stream, app.update_job_create(sid, body)), true
		end
		return method_not_allowed(stream), true
	end

	if #parts == 4 and parts[1] == 'api' and parts[2] == 'update' and parts[3] == 'jobs' then
		if req_method ~= 'GET' then return method_not_allowed(stream), true end
		return write_api_result(stream, app.update_job_get(sid, parts[4])), true
	end

	if #parts == 5 and parts[1] == 'api' and parts[2] == 'update' and parts[3] == 'jobs' and parts[5] == 'do' then
		if req_method ~= 'POST' then return method_not_allowed(stream), true end
		local body = body_or_reply()
		if not body then return true, true end
		return write_api_result(stream, app.update_job_do(sid, parts[4], body)), true
	end

	if req_path == '/api/update/uploads' then
		if req_method ~= 'POST' then return method_not_allowed(stream), true end
		return write_api_result(stream, app.update_job_upload(sid, stream, req_headers)), true
	end

	return false
end

local function handle_call_api(app, stream, req_method, req_path, sid, body_or_reply)
	if req_path ~= '/api/call' then
		return false
	end

	if req_method ~= 'POST' then return method_not_allowed(stream), true end
	local body = body_or_reply()
	if not body then return true, true end
	return write_api_result(stream, app.call(sid, body.topic, body.payload, body.timeout)), true
end

local function handle_api(svc, app, stream, req_method, req_path, req_headers)
	local parts = split_path(req_path)
	if parts[1] ~= 'api' then
		return false
	end

	local sid = session_id_from_headers(req_headers)

	local function body_or_reply()
		local body, err = read_json_body(stream)
		if not body then
			write_api_result(stream, nil, err)
			return nil
		end
		return body
	end

	local handled =
		select(2, handle_auth_api(app, stream, req_method, req_path, sid, body_or_reply))
		or select(2, handle_query_api(app, stream, req_method, req_path, sid, body_or_reply))
		or select(2, handle_config_api(app, stream, req_method, parts, sid, body_or_reply))
		or select(2, handle_fabric_api(app, stream, req_method, req_path, parts, sid))
		or select(2, handle_update_api(app, stream, req_method, req_path, parts, sid, req_headers, body_or_reply))
		or select(2, handle_call_api(app, stream, req_method, req_path, sid, body_or_reply))

	if handled then
		return true
	end

	write_text(stream, 404, 'not found\n')
	return true
end

local function onstream_factory(svc, app, opts)
	local www_root = opts.www_root
	local spawn_ws_client = assert(opts.spawn_ws_client, 'http transport requires spawn_ws_client')
	local ws_opts = assert(opts.ws_opts, 'http transport requires ws_opts')

	return function(server, stream)
		local req_headers = assert(stream:get_headers())
		local req_method = req_headers:get(':method') or 'GET'
		local req_path = req_headers:get(':path') or '/'

		svc:obs_log('info', {
			what = 'http_request',
			method = req_method,
			path = req_path,
		})

		if req_path == '/ws' then
			if req_method ~= 'GET' then
				write_text(stream, 405, 'method not allowed\n')
				return
			end

			return spawn_ws_client(function()
				return ws_client.run(svc, app, stream, req_headers, ws_opts)
			end)
		end

		if starts_with(req_path, '/api/') or req_path == '/api/health' or req_path == '/api/session' then
			handle_api(svc, app, stream, req_method, req_path, req_headers)
			return
		end

		if type(www_root) == 'string' and www_root ~= '' then
			if req_method ~= 'GET' and req_method ~= 'HEAD' then
				write_text(stream, 405, 'method not allowed\n')
				return
			end
			serve_static(svc, stream, req_method, req_path, www_root)
			return
		end

		write_text(stream, 404, 'not found\n')
	end
end

function M.build_handler(svc, app, opts)
	return onstream_factory(svc, app, opts or {})
end

function M.run(svc, app, opts)
	opts = opts or {}
	cq_bridge.install()

	local host = opts.host or '0.0.0.0'
	local port = opts.port or 80
	local server = assert(http_server.listen {
		host = host,
		port = port,
		onstream = M.build_handler(svc, app, opts),
		onerror = function(_, context, operation, err)
			svc:obs_log('warn', {
				what = 'http_error',
				context = tostring(context),
				operation = tostring(operation),
				err = tostring(err),
			})
		end,
	})

	function server:add_stream(stream)
		local ok, err = fibers.spawn(function()
			local run_ok, run_err
			if http_util and type(http_util.yieldable_pcall) == 'function' then
				run_ok, run_err = http_util.yieldable_pcall(self.onstream, self, stream)
			else
				run_ok, run_err = safe.pcall(self.onstream, self, stream)
			end
			if not run_ok then
				self:onerror()(self, stream, 'onstream', run_err)
			end
			if stream.state ~= 'closed' then
				stream:shutdown()
			end
		end)

		if ok ~= true then
			self:onerror()(self, stream, 'add_stream_spawn', err)
			if stream.state ~= 'closed' then
				stream:shutdown()
			end
		end
	end

	local ok_loop, err_loop = fibers.spawn(function()
		assert(server:loop())
	end)
	if ok_loop ~= true then
		error(err_loop or 'failed to start http server loop', 0)
	end

	svc:obs_log('info', {
		what = 'http_listening',
		host = host,
		port = port,
	})

	while true do
		fibers.perform(require('fibers.sleep').sleep_op(3600.0))
	end
end

M.session_id_from_headers = session_id_from_headers
return M
