-- Real devhost integration for cap/http/main over the local bus.
--
-- These tests use the real cqueues/lua-http backend.  They focus on the
-- capability-service seam: local handle return, listener/context ownership
-- transfer, service shutdown backstop termination, outgoing exchange, and
-- outgoing WebSocket transport.

local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'
local runtime = require 'fibers.runtime'
local bus    = require 'bus'

local http_request   = require 'http.request'
local http_headers   = require 'http.headers'
local http_server    = require 'http.server'
local http_websocket = require 'http.websocket'

local http_service = require 'services.http.service'
local sdk_mod      = require 'services.http.sdk'
local driver_mod   = require 'services.http.transport.cqueues_driver'
local lua_http     = require 'services.http.transport.lua_http'
local ws_wrap      = require 'services.http.transport.websocket'
local body_mod     = require 'services.http.body'

local M = {}

local function eq(a, b, msg)
	if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end
local function ok(v, msg) if not v then error(msg or 'assertion failed', 2) end return v end

local function yield_once()
	runtime.yield()
end

local function yield_many(n)
	for _ = 1, n do yield_once() end
end

local function wait_until(predicate, timeout, label)
	local deadline = runtime.now() + (timeout or 5)
	while not predicate() do
		if runtime.now() >= deadline then
			error('timed out waiting for ' .. (label or 'condition'), 2)
		end
		fibers.perform(sleep.sleep_op(0.01))
	end
end

local function response_headers(status, content_type)
	local h = http_headers.new()
	h:append(':status', tostring(status or 200))
	if content_type then h:append('content-type', content_type) end
	return h
end

local function http_uri(port, path)
	return ('http://127.0.0.1:%d%s'):format(port, path or '/')
end

local function ws_uri(port, path)
	return ('ws://127.0.0.1:%d%s'):format(port, path or '/ws')
end

local function start_cap_service(opts)
	opts = opts or {}
	local memory_sinks = opts.memory_sinks or {}
	local memory_sources = opts.memory_sources or {}
	local registry = opts.body_registry or body_mod.new_registry()
	registry:register_resolver('memory_sink', function (desc)
		local key = desc.ref or 'default'
		memory_sinks[key] = memory_sinks[key] or { chunks = {} }
		local rec = memory_sinks[key]
		return {
			write_chunk_op = function (_, chunk) rec.chunks[#rec.chunks + 1] = chunk; return fibers.always(true) end,
			finish_op = function () rec.finished = true; return fibers.always(true) end,
			terminate = function (_, reason) rec.terminated = reason or true; return true end,
		}
	end)
	registry:register_resolver('memory_source', function (desc)
		local key = desc.ref or 'default'
		local chunks = memory_sources[key] or {}
		local i = 0
		return {
			read_chunk_op = function ()
				return fibers.guard(function ()
					i = i + 1
					return fibers.always(chunks[i], nil)
				end)
			end,
			terminate = function (_, reason) memory_sources[key .. '_terminated'] = reason or true; return true end,
		}
	end)
	local b = bus.new()
	local svc_conn = b:connect({ origin_base = { kind = 'local' } })
	local svc = ok(http_service.start(svc_conn, {
		id = opts.id or 'main',
		backend_timeout = opts.backend_timeout or 2,
		connection_setup_timeout = opts.connection_setup_timeout or 2,
		intra_stream_timeout = opts.intra_stream_timeout or 2,
		max_accept_queue = opts.max_accept_queue or 32,
		body_registry = registry,
	}))

	local user_conn = b:connect({ origin_base = { kind = 'local' } })
	local ref = sdk_mod.new_ref(user_conn, opts.id or 'main')
	return b, svc, ref, memory_sinks
end

local function new_backend_listener(opts)
	opts = opts or {}
	local driver = ok(driver_mod.new { label = opts.label or 'http-service-real-backend' })
	local listener = ok(lua_http.listen {
		driver = driver,
		http_server = http_server,
		host = '127.0.0.1',
		port = 0,
		tls = false,
		max_accept_queue = opts.max_accept_queue or 32,
		connection_setup_timeout = opts.connection_setup_timeout or 2,
		intra_stream_timeout = opts.intra_stream_timeout or 2,
	})
	return listener, driver
end

local function start_backend_listener(scope, opts)
	local listener, driver = new_backend_listener(opts)
	ok(driver:start(scope), 'backend driver should start')
	ok(listener:start(scope), 'backend listener should start')
	ok(fibers.perform(listener:listen_op()), 'backend listener should bind')
	local _, _, port = listener:localname()
	ok(type(port) == 'number' and port > 0, 'backend listener should bind an ephemeral port')
	return listener, driver, port
end

local function run_http_client(driver, uri, body, method)
	return fibers.perform(driver:run_op('real-http-service-test-client', function ()
		local req = http_request.new_from_uri(uri)
		if method then req.headers:upsert(':method', method) end
		if body ~= nil then
			req.headers:upsert(':method', method or 'POST')
			req:set_body(body)
		end

		local headers, stream = assert(req:go(2))
		local response_body = assert(stream:get_body_as_string(2))
		return headers:get(':status'), response_body
	end))
end

function M.test_real_http_service_listen_returns_local_listener_handle()
	fibers.run(function ()
		local _, svc, ref = start_cap_service()

		local rep = ok(fibers.perform(ref:listen_op({
			host = '127.0.0.1',
			port = 0,
			tls = false,
		}, { timeout = 3 })))
		local listener = ok(rep.listener, 'listen should return a local listener handle')
		local _, _, port = listener:localname()
		ok(type(port) == 'number' and port > 0, 'listener should bind an ephemeral port')

		ok(fibers.spawn(function ()
			local ctx = ok(fibers.perform(listener:accept_op()))
			local req_headers = ok(fibers.perform(ctx:get_headers_op()))
			eq(req_headers:get(':path'), '/cap-test')
			ok(fibers.perform(ctx:write_headers_op(response_headers(200, 'text/plain'))))
			ok(fibers.perform(ctx:write_body_from_string_op('served-by-cap-http')))
		end))

		local status, body = run_http_client(svc._driver, http_uri(port, '/cap-test'))
		eq(status, '200')
		eq(body, 'served-by-cap-http')
		yield_many(8)
		local saw_context = false
		for _, ev in ipairs(svc:events()) do
			if ev.kind == 'context_admitted' then
				saw_context = true
				ok(ev.listener_id ~= nil, 'context_admitted should carry listener identity')
				ok(ev.context_id ~= nil, 'context_admitted should carry context identity')
			end
		end
		ok(saw_context, 'expected context_admitted event')

		svc:terminate('done')
	end)
end

function M.test_real_service_shutdown_terminates_live_listener_and_wakes_accept_op()
	fibers.run(function (scope)
		local _, svc, ref = start_cap_service()

		local rep = ok(fibers.perform(ref:listen_op({ host = '127.0.0.1', port = 0, tls = false }, { timeout = 3 })))
		local listener = ok(rep.listener)
		local accepted, accept_err

		ok(scope:spawn(function ()
			accepted, accept_err = fibers.perform(listener:accept_op())
		end))

		yield_many(4)
		svc:terminate('service_shutdown')
		yield_many(8)

		eq(accepted, nil)
		eq(accept_err, 'service_shutdown')
		ok(listener:is_closed(), 'service shutdown should terminate the live listener handle')
	end)
end

function M.test_real_accepted_context_survives_listener_close_after_ownership_transfer()
	fibers.run(function (scope)
		local _, svc, ref = start_cap_service()

		local rep = ok(fibers.perform(ref:listen_op({ host = '127.0.0.1', port = 0, tls = false }, { timeout = 3 })))
		local listener = ok(rep.listener)
		local _, _, port = listener:localname()
		local served = false

		ok(scope:spawn(function ()
			local ctx = ok(fibers.perform(listener:accept_op()))
			local req_headers = ok(fibers.perform(ctx:get_headers_op()))
			eq(req_headers:get(':path'), '/accepted-transfer')

			listener:terminate('listener_closed')
			ok(not ctx:is_closed(), 'accepted context should no longer be listener-owned')

			ok(fibers.perform(ctx:write_headers_op(response_headers(200, 'text/plain'))))
			ok(fibers.perform(ctx:write_body_from_string_op('context-still-owned-by-request')))
			served = true
		end))

		local status, body = run_http_client(svc._driver, http_uri(port, '/accepted-transfer'))
		eq(status, '200')
		eq(body, 'context-still-owned-by-request')
		ok(served, 'request scope should finish response after listener close')
		ok(listener:is_closed(), 'listener should be closed')

		svc:terminate('done')
	end)
end

function M.test_real_cap_exchange_get_and_post_round_trip_to_local_server()
	fibers.run(function (scope)
		local listener, driver, port = start_backend_listener(scope, { label = 'http-service-real-exchange-backend' })
		local _, svc, ref, sinks = start_cap_service({
			memory_sources = { post = { 'upload-', 'payload' } },
		})
		local handled = 0

		for _ = 1, 2 do
			ok(scope:spawn(function ()
				local ctx = ok(fibers.perform(listener:accept_op()))
				local req_headers = ok(fibers.perform(ctx:get_headers_op()))
				local method = req_headers:get(':method') or 'GET'
				local path = req_headers:get(':path') or '/'
				local payload = ''
				if method == 'POST' then
					payload = ':' .. ok(fibers.perform(ctx:read_body_as_string_op()))
				end
				handled = handled + 1
				ok(fibers.perform(ctx:write_headers_op(response_headers(200, 'text/plain'))))
				ok(fibers.perform(ctx:write_body_from_string_op(method .. ':' .. path .. payload)))
			end))
		end

		local get_rep = ok(fibers.perform(ref:exchange_op({
			uri = http_uri(port, '/out-get'),
			method = 'GET',
			headers = { ['x-test'] = 'get' },
			response_sink = { kind = 'memory_sink', ref = 'get' },
		}, { timeout = 3 })))
		eq(get_rep.result.status, '200')
		eq(table.concat(sinks.get.chunks), 'GET:/out-get')

		local post_rep = ok(fibers.perform(ref:exchange_op({
			uri = http_uri(port, '/out-post'),
			method = 'POST',
			headers = { ['x-test'] = 'post' },
			body_source = { kind = 'memory_source', ref = 'post' },
			response_sink = { kind = 'memory_sink', ref = 'post' },
		}, { timeout = 3 })))
		eq(post_rep.result.status, '200')
		eq(table.concat(sinks.post.chunks), 'POST:/out-post:upload-payload')
		eq(handled, 2)

		svc:terminate('done')
		listener:terminate('done')
		driver:terminate('done')
	end)
end

function M.test_real_open_exchange_handle_is_terminated_by_service_shutdown_backstop()
	fibers.run(function (scope)
		local listener, driver, port = start_backend_listener(scope, { label = 'http-service-real-open-exchange-backend' })
		local _, svc, ref = start_cap_service()
		local server_ready = false
		local release_server = false
		local server_done = false

		ok(scope:spawn(function ()
			local ctx = ok(fibers.perform(listener:accept_op()))
			ok(fibers.perform(ctx:get_headers_op()))
			ok(fibers.perform(ctx:write_headers_op(response_headers(200, 'text/plain'))))
			server_ready = true

			-- Keep the response stream open while the returned exchange handle is
			-- handed off to the caller and then terminated by the HTTP service
			-- shutdown backstop.  Do not leave an independent sleeper behind after
			-- the assertion: fibers.run would otherwise wait for it at scope exit.
			while not release_server do
				fibers.perform(sleep.sleep_op(0.01))
			end

			ctx:terminate('server_done')
			server_done = true
		end))

		local rep = ok(fibers.perform(ref:open_exchange_op({ uri = http_uri(port, '/held-open'), method = 'GET' }, { timeout = 3 })))
		local exchange = ok(rep.exchange, 'open_exchange should return a local exchange handle')
		eq(exchange:status(), '200')
		ok(server_ready, 'server should have written response headers')
		ok(not exchange:is_closed(), 'returned exchange should survive setup operation handoff')

		svc:terminate('service_shutdown')
		ok(exchange:is_closed(), 'service shutdown should terminate handed-off exchange as backend backstop')
		eq(exchange:why(), 'service_shutdown')

		release_server = true
		wait_until(function () return server_done end, 1, 'held-open server handler to finish')

		listener:terminate('done')
		driver:terminate('done')
	end)
end

function M.test_real_cap_connect_ws_send_receive_and_close_round_trip()
	fibers.run(function (scope)
		local listener, driver, port = start_backend_listener(scope, { label = 'http-service-real-ws-backend' })
		local _, svc, ref = start_cap_service()
		local server_done = false

		ok(scope:spawn(function ()
			local ctx = ok(fibers.perform(listener:accept_op()))
			local req_headers = ok(fibers.perform(ctx:get_headers_op()))
			local ws = ok(fibers.perform(ws_wrap.from_context_op(ctx, req_headers, {
				websocket_module = http_websocket,
			})))
			ok(fibers.perform(ws:accept_op({})))

			local data, opcode = fibers.perform(ws:receive_op())
			ok(data, 'server websocket should receive data')
			eq(opcode, 'text')
			ok(fibers.perform(ws:send_op(data .. ':via-cap-http', 'text')))
			fibers.perform(ws:close_op(1000, 'server_done'))
			server_done = true
		end))

		local rep = ok(fibers.perform(ref:connect_ws_op({ uri = ws_uri(port, '/ws') }, { timeout = 3 })))
		local ws = ok(rep.websocket, 'connect_ws should return a local WebSocket handle')
		ok(fibers.perform(ws:send_op('ping', 'text')))
		local data, opcode = fibers.perform(ws:receive_op())
		eq(data, 'ping:via-cap-http')
		eq(opcode, 'text')
		fibers.perform(ws:close_op(1000, 'client_done'))

		wait_until(function () return server_done end, 5, 'websocket server close')

		svc:terminate('done')
		listener:terminate('done')
		driver:terminate('done')
	end)
end

return M
