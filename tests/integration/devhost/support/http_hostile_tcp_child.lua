-- tests/integration/devhost/support/http_hostile_tcp_child.lua
-- Child-process payload for the hostile HTTP regression. It deliberately uses a
-- raw TCP upstream so cap/http/main's lua-http client sees incomplete and hostile
-- responses while a service-owned listener remains active in the same backend.

local function add_path(prefix)
	package.path = prefix .. '?.lua;' .. prefix .. '?/init.lua;' .. package.path
end

package.path = '../src/?.lua;' .. package.path
package.path = '../?.lua;../?/init.lua;./?.lua;./?/init.lua;' .. package.path
add_path('../vendor/lua-fibers/src/')
add_path('../vendor/lua-bus/src/')
add_path('../vendor/lua-trie/src/')
add_path('./')

local stdlib_ok, stdlib = pcall(require, 'posix.stdlib')
if stdlib_ok and stdlib and stdlib.setenv then
	stdlib.setenv('CONFIG_TARGET', 'services', true)
end

local fibers = require 'fibers'
local op     = require 'fibers.op'
local sleep  = require 'fibers.sleep'
local socket = require 'fibers.io.socket'
local bus    = require 'bus'

local http_headers = require 'http.headers'
local http_service = require 'services.http.service'
local sdk_mod      = require 'services.http.sdk'
local blob_source  = require 'devicecode.blob_source'

local LOG = os.getenv('HTTP_HOSTILE_CHILD_LOG') or '/tmp/devicecode-http-hostile-child.log'
local T0 = os.clock()

local function log(msg)
	local f = io.open(LOG, 'a')
	if f then
		f:write(('[%.6f] %s\n'):format(os.clock() - T0, tostring(msg)))
		f:close()
	end
end

local function fail(msg)
	log('child:fail ' .. tostring(msg))
	error(msg, 0)
end
local function ok(v, msg) if not v then fail(msg or 'assertion failed') end return v end
local function eq(a, b, msg) if a ~= b then fail((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end

local function env_num(name, default)
	local v = tonumber(os.getenv(name) or '')
	if v == nil then return default end
	return v
end

local function parse_modes()
	local s = os.getenv('HTTP_METRICS_TIMEOUT_HOSTILE_MODES') or 'partial_body,stall_no_response'
	local modes = {}
	for part in s:gmatch('[^,]+') do
		part = part:gsub('^%s+', ''):gsub('%s+$', '')
		if part ~= '' then modes[#modes + 1] = part end
	end
	if #modes == 0 then modes[1] = 'partial_body' end
	return modes
end

local function response_headers(status, content_type)
	local h = http_headers.new()
	h:append(':status', tostring(status or 200))
	if content_type then h:append('content-type', content_type) end
	return h
end

local function wait_until(predicate, timeout_s, label)
	local deadline = os.clock() + (timeout_s or 2.0)
	while true do
		local v = predicate()
		if v then return v end
		if os.clock() >= deadline then fail('timed out waiting for ' .. (label or 'condition')) end
		fibers.perform(sleep.sleep_op(0.005))
	end
end

local function write_all_op(stream, data)
	return fibers.run_scope_op(function ()
		local off = 1
		while off <= #data do
			local n, err = fibers.perform(stream:write_op(data:sub(off)))
			if n == nil then return nil, err or 'write_failed' end
			if n <= 0 then return nil, 'zero_length_write' end
			off = off + n
		end
		return true, nil
	end):wrap(function (st, _rep, okv, err)
		if st == 'ok' then return okv, err end
		return nil, okv or st
	end)
end

local function perform_with_timeout(label, operation, timeout_s)
	local which, a, b = fibers.perform(op.named_choice({
		value = operation,
		timeout = sleep.sleep_op(timeout_s or 1.0),
	}))
	if which == 'timeout' then return nil, label .. '_timeout' end
	return a, b
end

local function bind_inet_with_retry()
	local base = env_num('HTTP_METRICS_TIMEOUT_HOSTILE_PORT_BASE', 39000 + (os.time() % 20000))
	for i = 0, 200 do
		local port = base + i
		if port > 65000 then port = 39000 + (i % 20000) end
		local s = socket.listen_inet('127.0.0.1', port)
		if s then return s, port end
	end
	return nil, 'no_free_port'
end

local function read_request_head(stream)
	local buf = ''
	while not buf:find('\r\n\r\n', 1, true) and #buf < 32768 do
		local chunk, err = perform_with_timeout('read_request_head', stream:read_some_op(512), 1.0)
		if chunk == nil then return nil, err or 'closed' end
		buf = buf .. chunk
	end
	return buf, nil
end

local function parse_path(req)
	return req and req:match('^[A-Z]+%s+([^%s]+)') or '/'
end

local function parse_index(path)
	return tonumber(tostring(path or ''):match('(%d+)$'))
end

local function start_hostile_server(scope, records, auto_release_s)
	local server, port = bind_inet_with_retry()
	ok(server, port or 'bind_failed')
	ok(scope:spawn(function ()
		while true do
			local stream = fibers.perform(server:accept_op())
			if not stream then return end
			ok(scope:spawn(function ()
				local req = read_request_head(stream)
				local path = parse_path(req)
				local idx = parse_index(path)
				local rec = idx and records[idx] or nil
				if rec then
					rec.path = path
					rec.seen = true
				end
				local mode = rec and rec.mode or 'success'
				if mode == 'partial_status' then
					fibers.perform(write_all_op(stream, 'HTTP/1.1 202'))
				elseif mode == 'partial_headers' then
					fibers.perform(write_all_op(stream, 'HTTP/1.1 202 Accepted\r\nContent-Length: 100'))
				elseif mode == 'partial_body' then
					fibers.perform(write_all_op(stream, 'HTTP/1.1 202 Accepted\r\nContent-Length: 100\r\nConnection: close\r\n\r\nshort'))
				elseif mode == 'success' then
					fibers.perform(write_all_op(stream, 'HTTP/1.1 202 Accepted\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok'))
				else
					-- stall_no_response: the server has seen the request and intentionally
					-- gives the client no response bytes.
				end
				fibers.perform(sleep.sleep_op(auto_release_s or 0.1))
				if rec then rec.auto_released = true end
				if stream and type(stream.terminate) == 'function' then stream:terminate('hostile_done') end
			end))
		end
	end))
	return server, port
end

local function start_cap_service(opts)
	opts = opts or {}
	local b = bus.new()
	local svc_conn = b:connect({ origin_base = { kind = 'local' } })
	local svc = ok(http_service.open_handle(svc_conn, {
		id = 'main',
		backend_timeout = opts.backend_timeout or 2,
		connection_setup_timeout = opts.connection_setup_timeout or 2,
		intra_stream_timeout = opts.intra_stream_timeout or 2,
		max_accept_queue = 32,
	}))
	local user_conn = b:connect({ origin_base = { kind = 'local' } })
	return b, svc, sdk_mod.new_ref(user_conn, 'main')
end

local function http_uri(port, path)
	return ('http://127.0.0.1:%d%s'):format(port, path or '/')
end

local function assert_http_backend_ready(svc, label)
	local st = svc:stats()
	if st.backend ~= 'ready' then
		fail((label or 'http backend check') .. ': backend=' .. tostring(st.backend) .. ' last_error=' .. tostring(st.last_error or st.reason))
	end
	if tostring(st.last_error or ''):find('Bad file descriptor', 1, true) then
		fail((label or 'http backend check') .. ': EBADF reported: ' .. tostring(st.last_error))
	end
	return st
end

local function run_ui_raw_probe(scope, listener, port, i)
	log(('iter:%03d ui_probe_spawn_handler'):format(i))
	local handled = { accepted = false, wrote_body = false }
	ok(scope:spawn(function ()
		log(('iter:%03d ui_handler_accept_wait'):format(i))
		local ctx, aerr = fibers.perform(listener:accept_op())
		if not ctx then fail('ui accept failed: ' .. tostring(aerr)) end
		handled.accepted = true
		log(('iter:%03d ui_handler_accept_done'):format(i))
		local req_headers = ok(fibers.perform(ctx:get_headers_op()))
		log(('iter:%03d ui_handler_headers_done path=%s'):format(i, tostring(req_headers:get(':path'))))
		ok(fibers.perform(ctx:write_headers_op(response_headers(200, 'text/plain'))))
		log(('iter:%03d ui_handler_write_headers_done'):format(i))
		ok(fibers.perform(ctx:write_body_from_string_op(('listener-still-alive-hostile-%d'):format(i))))
		handled.wrote_body = true
		log(('iter:%03d ui_handler_write_body_done'):format(i))
	end))

	log(('iter:%03d ui_raw_client_begin'):format(i))
	local stream = ok(socket.connect_inet('127.0.0.1', port), 'raw UI client connect failed')
	local request = ('GET /ui-hostile/%03d HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n'):format(i)
	ok(fibers.perform(write_all_op(stream, request)), 'raw UI client write failed')
	local buf = ''
	while not buf:find('\r\n\r\n', 1, true) and #buf < 8192 do
		local chunk, err = perform_with_timeout('ui_raw_read', stream:read_some_op(512), 1.0)
		if chunk == nil then fail('raw UI client read failed: ' .. tostring(err)) end
		buf = buf .. chunk
	end
	if stream and type(stream.terminate) == 'function' then stream:terminate('ui_probe_done') end
	local status = buf:match('^HTTP/%d%.%d%s+(%d+)')
	log(('iter:%03d ui_raw_client_done status=%s body_len=%d'):format(i, tostring(status), math.max(0, #buf - (buf:find('\r\n\r\n', 1, true) or #buf))))
	eq(status, '200', 'UI raw probe status')
	wait_until(function () return handled.accepted and handled.wrote_body end, 1.0, 'UI handler completion')
end

local M = {}

local function run_child()
	log('child:start')
	local iterations = math.floor(env_num('HTTP_METRICS_TIMEOUT_HOSTILE_ITERATIONS', 4))
	local attempts_timeout = env_num('HTTP_METRICS_TIMEOUT_HOSTILE_TIMEOUT_S', 0.05)
	local backend_timeout = env_num('HTTP_METRICS_TIMEOUT_HOSTILE_BACKEND_TIMEOUT_S', 0.10)
	local intra_stream_timeout = env_num('HTTP_METRICS_TIMEOUT_HOSTILE_INTRA_STREAM_TIMEOUT_S', 0.10)
	local auto_release_s = env_num('HTTP_METRICS_TIMEOUT_HOSTILE_AUTO_RELEASE_S', 0.10)
	local ui_every = math.floor(env_num('HTTP_METRICS_TIMEOUT_HOSTILE_UI_EVERY', 3))
	local modes = parse_modes()

	fibers.run(function (scope)
		local records = {}
		local hostile_server, hostile_port = start_hostile_server(scope, records, auto_release_s)
		local _, svc, ref = start_cap_service({ backend_timeout = backend_timeout, intra_stream_timeout = intra_stream_timeout })
		local rep = ok(fibers.perform(ref:listen_op({ host = '127.0.0.1', port = 0, tls = false }, { timeout = 3 })))
		local ui_listener = ok(rep.listener)
		local _, _, ui_port = ui_listener:localname()
		log(('child:configured iterations=%d caller_timeout_s=%s backend_timeout_s=%s intra_stream_timeout_s=%s auto_release_s=%s ui_every=%d modes=%s hostile_port=%d ui_port=%d'):format(
			iterations, tostring(attempts_timeout), tostring(backend_timeout), tostring(intra_stream_timeout), tostring(auto_release_s), ui_every, table.concat(modes, ','), hostile_port, ui_port))

		for i = 1, iterations do
			local mode = modes[((i - 1) % #modes) + 1]
			records[i] = { mode = mode }
			log(('iter:%03d begin mode=%s'):format(i, mode))
			log(('iter:%03d before_exchange_op_build'):format(i))
			local response_op = ref:exchange_op({
				uri = http_uri(hostile_port, ('/mainflux-hostile/%03d'):format(i)),
				method = 'POST',
				headers = {
					['content-type'] = 'application/senml+json',
					['authorization'] = 'Bearer hostile-regression',
				},
				body_source = blob_source.from_string('[{"n":"x","v":1}]'),
			})
			log(('iter:%03d response_op_built'):format(i))
			log(('iter:%03d before_exchange_choice_perform'):format(i))
			local which, result, err = fibers.perform(op.named_choice({
				response = response_op,
				timeout = sleep.sleep_op(attempts_timeout),
			}))
			log(('iter:%03d exchange_choice_returned which=%s result=%s err=%s'):format(i, tostring(which), tostring(result), tostring(err)))
			eq(which, 'timeout', 'caller timeout should win for hostile exchange')
			log(('iter:%03d wait_rec_seen'):format(i))
			wait_until(function () return records[i].seen end, 1.0, 'hostile peer to see request ' .. tostring(i))
			log(('iter:%03d rec_seen path=%s'):format(i, tostring(records[i].path)))
			records[i].released = true
			log(('iter:%03d rec_released done=%s auto_released=%s'):format(i, tostring(records[i].done), tostring(records[i].auto_released)))
			assert_http_backend_ready(svc, ('iter:%03d post_exchange_backend_ready'):format(i))

			if ui_every > 0 and (i % ui_every) == 0 then
				log(('iter:%03d ui_probe_begin client=raw'):format(i))
				run_ui_raw_probe(scope, ui_listener, ui_port, i)
				assert_http_backend_ready(svc, ('iter:%03d post_ui_probe_backend_ready'):format(i))
			end
		end

		log('child:post_loop_checks')
		assert_http_backend_ready(svc, 'post_loop_backend_ready')
		local final_i = iterations + 1
		records[final_i] = { mode = 'success' }
		log('child:final_retry_begin')
		local final = ok(fibers.perform(ref:exchange_op({
			uri = http_uri(hostile_port, ('/mainflux-hostile/%03d'):format(final_i)),
			method = 'POST',
			headers = { ['content-type'] = 'application/senml+json' },
			body_source = blob_source.from_string('[{"n":"final","v":1}]'),
		})))
		eq(final.result.status, '202', 'final retry status')
		assert_http_backend_ready(svc, 'after_final_retry_backend_ready')
		wait_until(function () return (svc:stats().active_exchanges or 0) == 0 end, 1.0, 'active exchanges to drain')
		log('child:success')
		io.stdout:flush()
		io.stderr:flush()
		os.exit(0)
	end)
end

function M.run()
	return run_child()
end

if ... == nil then
	return M.run()
end

return M
