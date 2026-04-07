--
-- lua-http transport for services/ui.lua.
--
-- This version also provides firmware upload and transfer status APIs:
--   * POST /api/fabric/firmware/<link_id>        raw binary body
--   * GET  /api/fabric/transfer/<id>
--   * POST /api/fabric/transfer/<id>/abort

local fibers       = require 'fibers'
local file         = require 'fibers.io.file'
local http_server  = require 'http.server'
local http_headers = require 'http.headers'
local http_util    = require 'http.util'
local websocket    = require 'http.websocket'
local cjson        = require 'cjson.safe'
local cq_bridge    = require 'services.ui.cqueues_bridge'
local blob_source  = require 'services.fabric.blob_source'

local perform = fibers.perform

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
	['.html'] = 'text/html; charset=utf-8',
	['.js'] = 'application/javascript',
	['.css'] = 'text/css',
	['.json'] = 'application/json',
	['.svg'] = 'image/svg+xml',
	['.png'] = 'image/png',
	['.jpg'] = 'image/jpeg',
	['.jpeg'] = 'image/jpeg',
	['.ico'] = 'image/x-icon',
	['.webp'] = 'image/webp',
	['.woff'] = 'font/woff',
	['.woff2'] = 'font/woff2',
	['.ttf'] = 'font/ttf',
	['.map'] = 'application/json',
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

local function read_body_string(stream)
	if type(stream.get_body_as_string) == 'function' then
		local ok, body = pcall(function()
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
		return nil, 'body_read_failed: ' .. tostring(err)
	end
	if body == '' then
		return {}, nil
	end
	local obj, jerr = cjson.decode(body)
	if obj == nil then
		return nil, 'json_decode_failed: ' .. tostring(jerr)
	end
	if type(obj) ~= 'table' then
		return nil, 'json body must decode to a table'
	end
	return obj, nil
end

local function set_session_cookie_headers(session_id, expires_at)
	local cookie = ('devicecode_session=%s; Path=/; HttpOnly; SameSite=Strict'):format(tostring(session_id))
	if expires_at then
		-- Server-side session expiry remains authoritative.
	end
	return {
		{ 'set-cookie', cookie },
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

local function serve_static(stream, req_method, req_path, www_root)
	local path = static_path(www_root, req_path)
	if not path then
		write_text(stream, 404, 'not found\n')
		return true
	end

	local s, err = file.open(path, 'r')
	if not s then
		write_text(stream, 404, 'not found\n')
		return true
	end

	local h = response_headers(200, mime_for_path(path))
	assert(stream:write_headers(h, req_method == 'HEAD'))

	if req_method ~= 'HEAD' then
		while true do
			local chunk, rerr = s:read_some(16384)
			if rerr ~= nil then
				pcall(function() s:close() end)
				write_text(stream, 500, 'read error\n')
				return true
			end
			if chunk == nil then break end
			assert(stream:write_chunk(chunk, false))
		end
		assert(stream:write_chunk('', true))
	end

	s:close()
	return true
end

local function ws_send(ws, obj)
	local txt = cjson.encode(obj or {}) or '{"ok":false,"err":"json_encode_failed"}'
	return ws:send(txt)
end

local function infer_filename(req_headers, fallback)
	local v = req_headers:get('x-filename')
	if type(v) == 'string' and v ~= '' then return v end
	return fallback or 'firmware.bin'
end

local function infer_format(filename, req_headers)
	local v = req_headers:get('x-format')
	if type(v) == 'string' and v ~= '' then return v end

	filename = tostring(filename or '')
	if filename:match('%.uf2$') then return 'uf2' end
	if filename:match('%.bin$') then return 'bin' end
	return 'bin'
end

local function handle_ws(svc, api, stream, req_headers)
	local ws, werr = websocket.new_from_stream(stream, req_headers)
	if not ws then
		write_text(stream, 400, 'websocket upgrade failed: ' .. tostring(werr) .. '\n')
		return
	end

	assert(ws:accept())

	local sid0 = session_id_from_headers(req_headers)
	local current_session = sid0

	svc:obs_log('info', { what = 'ws_connected' })

	while true do
		local msg, opcode, err = ws:receive()
		if msg == nil then
			svc:obs_log('info', { what = 'ws_disconnected', err = tostring(err) })
			break
		end

		if opcode ~= 'text' then
			ws_send(ws, { ok = false, err = 'only text frames are supported' })
		else
			local obj, jerr = cjson.decode(msg)
			if obj == nil or type(obj) ~= 'table' then
				ws_send(ws, {
					ok  = false,
					err = 'invalid_json: ' .. tostring(jerr),
				})
			else
				local id = obj.id
				local op = obj.op

				local function reply(payload)
					payload = payload or {}
					payload.id = id
					return ws_send(ws, payload)
				end

				if op == 'hello' then
					reply({
						ok      = true,
						service = svc.name,
					})

				elseif op == 'session' then
					local out, e = api.get_session(obj.session_id or current_session)
					reply({
						ok   = (out ~= nil),
						data = out,
						err  = (out == nil) and tostring(e) or nil,
					})

				elseif op == 'health' then
					local out, e = api.health()
					reply({
						ok   = (out ~= nil),
						data = out,
						err  = (out == nil) and tostring(e) or nil,
					})

				elseif op == 'login' then
					local out, e = api.login(obj.username, obj.password)
					if out and out.session_id then
						current_session = out.session_id
					end
					reply({
						ok   = (out ~= nil),
						data = out,
						err  = (out == nil) and tostring(e) or nil,
					})

				elseif op == 'logout' then
					local ok, e = api.logout(obj.session_id or current_session)
					if ok then
						current_session = nil
					end
					reply({
						ok  = (ok == true),
						err = (ok ~= true) and tostring(e) or nil,
					})

				elseif op == 'config_set' then
					local out, e = api.config_set(
						obj.session_id or current_session,
						obj.service,
						obj.data
					)
					reply({
						ok   = (out ~= nil),
						data = out,
						err  = (out == nil) and tostring(e) or nil,
					})

				elseif op == 'rpc_call' then
					local out, e = api.rpc_call(
						obj.session_id or current_session,
						obj.service,
						obj.method,
						obj.payload,
						obj.timeout
					)
					reply({
						ok   = (out ~= nil),
						data = out,
						err  = (out == nil) and tostring(e) or nil,
					})

				elseif op == 'firmware_send' then
					reply({
						ok  = false,
						err = 'websocket firmware upload is not implemented in this first pass',
					})

				elseif op == 'transfer_status' then
					local out, e = api.transfer_status(
						obj.session_id or current_session,
						obj.transfer_id
					)
					reply({
						ok   = (out ~= nil),
						data = out,
						err  = (out == nil) and tostring(e) or nil,
					})

				elseif op == 'transfer_abort' then
					local out, e = api.transfer_abort(
						obj.session_id or current_session,
						obj.transfer_id
					)
					reply({
						ok   = (out ~= nil),
						data = out,
						err  = (out == nil) and tostring(e) or nil,
					})

				else
					reply({
						ok  = false,
						err = 'unknown op: ' .. tostring(op),
					})
				end
			end
		end
	end

	pcall(function() ws:close() end)
end

local function handle_api(svc, api, stream, req_method, req_path, req_headers)
	local parts = split_path(req_path)

	if parts[1] ~= 'api' then
		return false
	end

	if req_path == '/api/login' then
		if req_method ~= 'POST' then
			write_text(stream, 405, 'method not allowed\n')
			return true
		end

		local body, err = read_json_body(stream)
		if not body then
			write_json(stream, 400, { ok = false, err = err })
			return true
		end

		local out, lerr = api.login(body.username, body.password)
		if not out then
			write_json(stream, 401, { ok = false, err = tostring(lerr) })
			return true
		end

		write_json(
			stream,
			200,
			{ ok = true, data = out },
			set_session_cookie_headers(out.session_id, out.expires_at)
		)
		return true
	end

	if req_path == '/api/logout' then
		if req_method ~= 'POST' then
			write_text(stream, 405, 'method not allowed\n')
			return true
		end

		local sid = session_id_from_headers(req_headers)
		local body = read_json_body(stream)
		if type(body) == 'table' and body.session_id then
			sid = body.session_id
		end

		local ok, err = api.logout(sid)
		write_json(
			stream,
			(ok == true) and 200 or 400,
			{ ok = (ok == true), err = (ok ~= true) and tostring(err) or nil },
			clear_session_cookie_headers()
		)
		return true
	end

	if req_path == '/api/session' then
		if req_method ~= 'GET' then
			write_text(stream, 405, 'method not allowed\n')
			return true
		end

		local sid = session_id_from_headers(req_headers)
		local out, err = api.get_session(sid)
		write_json(stream, out and 200 or 401, {
			ok   = (out ~= nil),
			data = out,
			err  = (out == nil) and tostring(err) or nil,
		})
		return true
	end

	if req_path == '/api/health' then
		if req_method ~= 'GET' then
			write_text(stream, 405, 'method not allowed\n')
			return true
		end

		local out, err = api.health()
		write_json(stream, out and 200 or 500, {
			ok   = (out ~= nil),
			data = out,
			err  = (out == nil) and tostring(err) or nil,
		})
		return true
	end

	if #parts == 3 and parts[1] == 'api' and parts[2] == 'config' then
		if req_method ~= 'POST' then
			write_text(stream, 405, 'method not allowed\n')
			return true
		end

		local body, err = read_json_body(stream)
		if not body then
			write_json(stream, 400, { ok = false, err = err })
			return true
		end

		local sid = session_id_from_headers(req_headers) or body.session_id
		local out, cerr = api.config_set(sid, parts[3], body.data)
		write_json(stream, out and 200 or 400, {
			ok   = (out ~= nil),
			data = out,
			err  = (out == nil) and tostring(cerr) or nil,
		})
		return true
	end

	if #parts == 4 and parts[1] == 'api' and parts[2] == 'rpc' then
		if req_method ~= 'POST' then
			write_text(stream, 405, 'method not allowed\n')
			return true
		end

		local body, err = read_json_body(stream)
		if not body then
			write_json(stream, 400, { ok = false, err = err })
			return true
		end

		local sid = session_id_from_headers(req_headers) or body.session_id
		local out, rerr = api.rpc_call(sid, parts[3], parts[4], body.payload, body.timeout)
		write_json(stream, out and 200 or 400, {
			ok   = (out ~= nil),
			data = out,
			err  = (out == nil) and tostring(rerr) or nil,
		})
		return true
	end

	if #parts == 4 and parts[1] == 'api' and parts[2] == 'fabric' and parts[3] == 'firmware' then
		if req_method ~= 'POST' then
			write_text(stream, 405, 'method not allowed\n')
			return true
		end

		local sid = session_id_from_headers(req_headers)
		local body, err = read_body_string(stream)
		if body == nil then
			write_json(stream, 400, { ok = false, err = 'body_read_failed: ' .. tostring(err) })
			return true
		end

		local filename = infer_filename(req_headers)
		local format   = infer_format(filename, req_headers)
		local source   = blob_source.from_string(filename, body, { format = format })

		local out, ferr = api.firmware_send(sid, parts[4], source, {
			kind   = 'firmware.rp2350',
			name   = filename,
			format = format,
		})

		write_json(stream, out and 200 or 400, {
			ok   = (out ~= nil),
			data = out,
			err  = (out == nil) and tostring(ferr) or nil,
		})
		return true
	end

	if #parts == 4 and parts[1] == 'api' and parts[2] == 'fabric' and parts[3] == 'transfer' then
		if req_method ~= 'GET' then
			write_text(stream, 405, 'method not allowed\n')
			return true
		end

		local sid = session_id_from_headers(req_headers)
		local out, terr = api.transfer_status(sid, parts[4])
		write_json(stream, out and 200 or 400, {
			ok   = (out ~= nil),
			data = out,
			err  = (out == nil) and tostring(terr) or nil,
		})
		return true
	end

	if #parts == 5 and parts[1] == 'api' and parts[2] == 'fabric' and parts[3] == 'transfer' and parts[5] == 'abort' then
		if req_method ~= 'POST' then
			write_text(stream, 405, 'method not allowed\n')
			return true
		end

		local sid = session_id_from_headers(req_headers)
		local out, terr = api.transfer_abort(sid, parts[4])
		write_json(stream, out and 200 or 400, {
			ok   = (out ~= nil),
			data = out,
			err  = (out == nil) and tostring(terr) or nil,
		})
		return true
	end

	write_text(stream, 404, 'not found\n')
	return true
end

local function onstream_factory(svc, api, opts)
	local www_root = opts.www_root

	return function(server, stream)
		local req_headers = assert(stream:get_headers())
		local req_method  = req_headers:get(':method') or 'GET'
		local req_path    = req_headers:get(':path') or '/'

		svc:obs_log('info', {
			what   = 'http_request',
			method = req_method,
			path   = req_path,
		})

		if req_path == '/ws' then
			if req_method ~= 'GET' then
				write_text(stream, 405, 'method not allowed\n')
				return
			end
			handle_ws(svc, api, stream, req_headers)
			return
		end

		if starts_with(req_path, '/api/') or req_path == '/api/health' or req_path == '/api/session' then
			handle_api(svc, api, stream, req_method, req_path, req_headers)
			return
		end

		if type(www_root) == 'string' and www_root ~= '' then
			if req_method ~= 'GET' and req_method ~= 'HEAD' then
				write_text(stream, 405, 'method not allowed\n')
				return
			end
			serve_static(stream, req_method, req_path, www_root)
			return
		end

		write_text(stream, 404, 'not found\n')
	end
end

function M.build_handler(svc, api, opts)
	return onstream_factory(svc, api, opts or {})
end

function M.run(svc, api, opts)
	opts = opts or {}

	cq_bridge.install()

	local host = opts.host or '0.0.0.0'
	local port = opts.port or 80

	local server = assert(http_server.listen {
		host = host,
		port = port,
		onstream = M.build_handler(svc, api, opts),
		onerror = function(_, context, operation, err)
			svc:obs_log('warn', {
				what      = 'http_error',
				context   = tostring(context),
				operation = tostring(operation),
				err       = tostring(err),
			})
		end,
	})

	function server:add_stream(stream)
		fibers.spawn(function()
			local ok, err
			if http_util and type(http_util.yieldable_pcall) == 'function' then
				ok, err = http_util.yieldable_pcall(self.onstream, self, stream)
			else
				ok, err = pcall(self.onstream, self, stream)
			end

			if not ok then
				self:onerror()(self, stream, 'onstream', err)
			end

			if stream.state ~= 'closed' then
				pcall(function() stream:shutdown() end)
			end
		end)
	end

	fibers.spawn(function()
		assert(server:loop())
	end)

	svc:obs_log('info', {
		what = 'http_listening',
		host = host,
		port = port,
	})

	while true do
		perform(require('fibers.sleep').sleep_op(3600.0))
	end
end

return M
