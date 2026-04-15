-- services/ui/http_transport.lua
--
-- lua-http transport for services/ui.lua.
--
-- Session/auth:
--   POST /api/login
--   POST /api/logout
--   GET  /api/session
--   GET  /api/health
--
-- Retained reads:
--   GET  /api/config/<service>
--   GET  /api/service/<service>/status
--   GET  /api/fabric
--   GET  /api/fabric/link/<link_id>
--   GET  /api/capabilities
--
-- Mutations / RPC:
--   POST /api/config/<service>
--   POST /api/rpc/<service>/<method>
--
-- Fabric transfer helpers:
--   POST /api/fabric/firmware/<link_id>   (raw body; x-filename, x-format, x-transfer-chunk-raw)
--   GET  /api/fabric/transfer/<id>
--   POST /api/fabric/transfer/<id>/abort
--
-- WebSocket:
--   GET  /ws
--
-- WebSocket operations:
--   hello
--   session
--   health
--   login
--   logout
--   config_get
--   config_set
--   service_status
--   fabric_status
--   fabric_link_status
--   capability_snapshot
--   rpc_call
--   transfer_status
--   transfer_abort
--   retained_watch_start   { stream_id, topic, replay_idle_s? }
--   retained_watch_stop    { stream_id }

local fibers       = require 'fibers'
local mailbox      = require 'fibers.mailbox'
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

local function set_session_cookie_headers(session_id)
	local cookie = ('devicecode_session=%s; Path=/; HttpOnly; SameSite=Strict'):format(tostring(session_id))
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

	local s, _ = file.open(path, 'r')
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

local function infer_transfer_chunk_raw(req_headers)
	local v = req_headers:get('x-transfer-chunk-raw')
	if v == nil or v == '' then return nil, nil end

	local n = tonumber(v)
	if type(n) ~= 'number' or n <= 0 or n % 1 ~= 0 then
		return nil, 'x-transfer-chunk-raw must be a positive integer'
	end

	return math.floor(n), nil
end

local function status_for_error(err, fallback)
	err = tostring(err or '')
	if err == '' then
		return fallback or 500
	end

	if err == 'missing session'
		or err == 'invalid or expired session'
		or err == 'invalid credentials'
		or err == 'login failed'
	then
		return 401
	end

	if err == 'not found'
		or err:match('^unknown transfer')
		or err:match('^unknown link')
	then
		return 404
	end

	if err:find('timeout', 1, true) then
		return 504
	end

	if err:find('busy', 1, true) or err:find('full', 1, true) then
		return 503
	end

	if err:find('not configured', 1, true) then
		return 503
	end

	if err:find('transport', 1, true)
		or err:find('send_', 1, true)
		or err:find('call failed', 1, true)
		or err:find('upstream', 1, true)
	then
		return 502
	end

	if err:find('must be', 1, true)
		or err:find('invalid', 1, true)
		or err:find('missing', 1, true)
		or err:find('json_', 1, true)
		or err:find('payload', 1, true)
		or err:find('unsupported', 1, true)
	then
		return 400
	end

	return fallback or 500
end

local function write_api_result(stream, out, err, ok_status, err_fallback)
	if out ~= nil then
		write_json(stream, ok_status or 200, {
			ok   = true,
			data = out,
		})
		return true
	end

	write_json(stream, status_for_error(err, err_fallback), {
		ok  = false,
		err = tostring(err),
	})
	return true
end

local function handle_ws(svc, api, stream, req_headers)
	local ws, werr = websocket.new_from_stream(stream, req_headers)
	if not ws then
		write_text(stream, 400, 'websocket upgrade failed: ' .. tostring(werr) .. '\n')
		return
	end

	assert(ws:accept())

	local out_tx, out_rx = mailbox.new(128, { full = 'drop_oldest' })
	fibers.spawn(function()
		while true do
			local item = perform(out_rx:recv_op())
			if item == nil then return end
			local ok = pcall(function() ws_send(ws, item) end)
			if not ok then return end
		end
	end)

	local function send_ws(item)
		local ok = out_tx:send(item)
		return ok == true
	end

	local sid0 = session_id_from_headers(req_headers)
	local current_session = sid0
	local watches = {}

	local function close_watch(stream_id)
		local rec = watches[stream_id]
		if not rec then return false end
		watches[stream_id] = nil
		pcall(function() rec.watch:close('client_stop') end)
		return true
	end

	local function close_all_watches()
		for stream_id in pairs(watches) do
			close_watch(stream_id)
		end
	end

	svc:obs_log('info', { what = 'ws_connected' })

	while true do
		local msg, opcode, err = ws:receive()
		if msg == nil then
			svc:obs_log('info', { what = 'ws_disconnected', err = tostring(err) })
			break
		end

		if opcode ~= 'text' then
			send_ws({ ok = false, err = 'only text frames are supported' })
		else
			local obj, jerr = cjson.decode(msg)
			if obj == nil or type(obj) ~= 'table' then
				send_ws({
					ok  = false,
					err = 'invalid_json: ' .. tostring(jerr),
				})
			else
				local id = obj.id
				local op_name = obj.op

				local function reply(payload)
					payload = payload or {}
					payload.id = id
					return send_ws(payload)
				end

				if op_name == 'hello' then
					reply({ ok = true, service = svc.name })

				elseif op_name == 'session' then
					local out, e = api.get_session(obj.session_id or current_session)
					reply({ ok = (out ~= nil), data = out, err = (out == nil) and tostring(e) or nil })

				elseif op_name == 'health' then
					local out, e = api.health()
					reply({ ok = (out ~= nil), data = out, err = (out == nil) and tostring(e) or nil })

				elseif op_name == 'login' then
					local out, e = api.login(obj.username, obj.password)
					if out and out.session_id then current_session = out.session_id end
					reply({ ok = (out ~= nil), data = out, err = (out == nil) and tostring(e) or nil })

				elseif op_name == 'logout' then
					local ok, e = api.logout(obj.session_id or current_session)
					if ok then current_session = nil end
					reply({ ok = (ok == true), err = (ok ~= true) and tostring(e) or nil })

				elseif op_name == 'config_get' then
					local out, e = api.config_get(obj.session_id or current_session, obj.service)
					reply({ ok = (out ~= nil), data = out, err = (out == nil) and tostring(e) or nil })

				elseif op_name == 'config_set' then
					local out, e = api.config_set(obj.session_id or current_session, obj.service, obj.data)
					reply({ ok = (out ~= nil), data = out, err = (out == nil) and tostring(e) or nil })

				elseif op_name == 'service_status' then
					local out, e = api.service_status(obj.session_id or current_session, obj.service)
					reply({ ok = (out ~= nil), data = out, err = (out == nil) and tostring(e) or nil })

				elseif op_name == 'fabric_status' then
					local out, e = api.fabric_status(obj.session_id or current_session)
					reply({ ok = (out ~= nil), data = out, err = (out == nil) and tostring(e) or nil })

				elseif op_name == 'fabric_link_status' then
					local out, e = api.fabric_link_status(obj.session_id or current_session, obj.link_id)
					reply({ ok = (out ~= nil), data = out, err = (out == nil) and tostring(e) or nil })

				elseif op_name == 'capability_snapshot' then
					local out, e = api.capability_snapshot(obj.session_id or current_session)
					reply({ ok = (out ~= nil), data = out, err = (out == nil) and tostring(e) or nil })

				elseif op_name == 'rpc_call' then
					local out, e = api.rpc_call(obj.session_id or current_session, obj.service, obj.method, obj.payload, obj.timeout)
					reply({ ok = (out ~= nil), data = out, err = (out == nil) and tostring(e) or nil })

				elseif op_name == 'firmware_send' then
					reply({ ok = false, err = 'websocket firmware upload is not implemented in this first pass' })

				elseif op_name == 'transfer_status' then
					local out, e = api.transfer_status(obj.session_id or current_session, obj.transfer_id)
					reply({ ok = (out ~= nil), data = out, err = (out == nil) and tostring(e) or nil })

				elseif op_name == 'transfer_abort' then
					local out, e = api.transfer_abort(obj.session_id or current_session, obj.transfer_id)
					reply({ ok = (out ~= nil), data = out, err = (out == nil) and tostring(e) or nil })

				elseif op_name == 'retained_watch_start' then
					local stream_id = obj.stream_id
					if type(stream_id) ~= 'string' or stream_id == '' then
						reply({ ok = false, err = 'stream_id must be a non-empty string' })
					else
						close_watch(stream_id)
						local watch, e = api.retained_watch(obj.session_id or current_session, obj.topic, {
							replay_idle_s = obj.replay_idle_s,
							queue_len     = obj.queue_len,
							event_queue   = obj.event_queue,
						})
						if not watch then
							reply({ ok = false, err = tostring(e) })
						else
							watches[stream_id] = { watch = watch }
							fibers.spawn(function()
								while watches[stream_id] do
									local ev, werr = perform(watch:recv_op())
									if not ev then
										send_ws({
											op   = 'retained_watch_end',
											id   = stream_id,
											ok   = false,
											err  = tostring(werr or 'closed'),
										})
										close_watch(stream_id)
										return
									end
									send_ws({
										op    = 'retained_watch_event',
										id    = stream_id,
										event = ev,
									})
									if ev.kind == 'closed' then
										close_watch(stream_id)
										return
									end
								end
							end)
							reply({ ok = true, data = { stream_id = stream_id } })
						end
					end

				elseif op_name == 'retained_watch_stop' then
					local stream_id = obj.stream_id
					if type(stream_id) ~= 'string' or stream_id == '' then
						reply({ ok = false, err = 'stream_id must be a non-empty string' })
					else
						local ok = close_watch(stream_id)
						reply({ ok = ok == true, err = (ok ~= true) and 'unknown stream' or nil })
					end

				else
					reply({ ok = false, err = 'unknown op: ' .. tostring(op_name) })
				end
			end
		end
	end

	close_all_watches()
	pcall(function() out_tx:close('ws_closed') end)
	pcall(function() ws:close() end)
end

local function handle_api(_svc, api, stream, req_method, req_path, req_headers)
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
			write_json(stream, status_for_error(lerr, 401), { ok = false, err = tostring(lerr) })
			return true
		end

		write_json(stream, 200, { ok = true, data = out }, set_session_cookie_headers(out.session_id))
		return true
	end

	if req_path == '/api/logout' then
		if req_method ~= 'POST' then
			write_text(stream, 405, 'method not allowed\n')
			return true
		end

		local sid = session_id_from_headers(req_headers)
		local body, err = read_json_body(stream)
		if not body then
			write_json(stream, 400, { ok = false, err = err })
			return true
		end
		if body.session_id then sid = body.session_id end

		local ok, lerr = api.logout(sid)
		if ok == true then
			write_json(stream, 200, { ok = true }, clear_session_cookie_headers())
		else
			write_json(stream, status_for_error(lerr, 401), { ok = false, err = tostring(lerr) }, clear_session_cookie_headers())
		end
		return true
	end

	if req_path == '/api/session' then
		if req_method ~= 'GET' then
			write_text(stream, 405, 'method not allowed\n')
			return true
		end
		local sid = session_id_from_headers(req_headers)
		local out, err = api.get_session(sid)
		return write_api_result(stream, out, err, 200, 401)
	end

	if req_path == '/api/health' then
		if req_method ~= 'GET' then
			write_text(stream, 405, 'method not allowed\n')
			return true
		end
		local out, err = api.health()
		return write_api_result(stream, out, err, 200, 500)
	end

	if req_path == '/api/capabilities' then
		if req_method ~= 'GET' then
			write_text(stream, 405, 'method not allowed\n')
			return true
		end
		local sid = session_id_from_headers(req_headers)
		local out, err = api.capability_snapshot(sid)
		return write_api_result(stream, out, err, 200, 401)
	end

	if #parts == 3 and parts[1] == 'api' and parts[2] == 'config' then
		if req_method == 'GET' then
			local sid = session_id_from_headers(req_headers)
			local out, err = api.config_get(sid, parts[3])
			return write_api_result(stream, out, err, 200, 401)
		end

		if req_method == 'POST' then
			local body, err = read_json_body(stream)
			if not body then
				write_json(stream, 400, { ok = false, err = err })
				return true
			end
			local sid = session_id_from_headers(req_headers) or body.session_id
			local out, cerr = api.config_set(sid, parts[3], body.data)
			return write_api_result(stream, out, cerr, 200, 400)
		end

		write_text(stream, 405, 'method not allowed\n')
		return true
	end

	if #parts == 4 and parts[1] == 'api' and parts[2] == 'service' and parts[4] == 'status' then
		if req_method ~= 'GET' then
			write_text(stream, 405, 'method not allowed\n')
			return true
		end
		local sid = session_id_from_headers(req_headers)
		local out, err = api.service_status(sid, parts[3])
		return write_api_result(stream, out, err, 200, 401)
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
		return write_api_result(stream, out, rerr, 200, 502)
	end

	if req_path == '/api/fabric' then
		if req_method ~= 'GET' then
			write_text(stream, 405, 'method not allowed\n')
			return true
		end
		local sid = session_id_from_headers(req_headers)
		local out, err = api.fabric_status(sid)
		return write_api_result(stream, out, err, 200, 401)
	end

	if #parts == 4 and parts[1] == 'api' and parts[2] == 'fabric' and parts[3] == 'link' then
		if req_method ~= 'GET' then
			write_text(stream, 405, 'method not allowed\n')
			return true
		end
		local sid = session_id_from_headers(req_headers)
		local out, err = api.fabric_link_status(sid, parts[4])
		return write_api_result(stream, out, err, 200, 401)
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
		local chunk_raw, cerr = infer_transfer_chunk_raw(req_headers)
		if cerr then
			write_json(stream, 400, { ok = false, err = cerr })
			return true
		end
		local source   = blob_source.from_string(filename, body, { format = format })

		local meta = {
			kind   = 'firmware.rp2350',
			name   = filename,
			format = format,
		}
		if chunk_raw ~= nil then meta.chunk_raw = chunk_raw end

		local out, ferr = api.firmware_send(sid, parts[4], source, meta)
		return write_api_result(stream, out, ferr, 200, 400)
	end

	if #parts == 4 and parts[1] == 'api' and parts[2] == 'fabric' and parts[3] == 'transfer' then
		if req_method ~= 'GET' then
			write_text(stream, 405, 'method not allowed\n')
			return true
		end
		local sid = session_id_from_headers(req_headers)
		local out, terr = api.transfer_status(sid, parts[4])
		return write_api_result(stream, out, terr, 200, 400)
	end

	if #parts == 5 and parts[1] == 'api' and parts[2] == 'fabric' and parts[3] == 'transfer' and parts[5] == 'abort' then
		if req_method ~= 'POST' then
			write_text(stream, 405, 'method not allowed\n')
			return true
		end
		local sid = session_id_from_headers(req_headers)
		local out, terr = api.transfer_abort(sid, parts[4])
		return write_api_result(stream, out, terr, 200, 400)
	end

	write_text(stream, 404, 'not found\n')
	return true
end

local function request_log_level(req_method)
	if req_method == 'GET' or req_method == 'HEAD' then
		return 'debug'
	end
	return 'info'
end

local function onstream_factory(svc, api, opts)
	local www_root = opts.www_root

	return function(server, stream)
		local req_headers = assert(stream:get_headers())
		local req_method  = req_headers:get(':method') or 'GET'
		local req_path    = req_headers:get(':path') or '/'

		svc:obs_log(request_log_level(req_method), {
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
