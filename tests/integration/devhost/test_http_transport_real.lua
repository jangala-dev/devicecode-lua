-- tests/integration/devhost/test_http_transport_real.lua
--
-- Real devhost integration tests for the HTTP transport seam.
--
-- These tests intentionally use real cqueues and lua-http modules. There are no
-- fakes or mocks in this file. Add this module to the top-level integration
-- runner when the devhost/CI image has cqueues and lua-http installed.

local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'
local runtime = require 'fibers.runtime'

local cqueues_condition = require 'cqueues.condition'
local http_server       = require 'http.server'
local http_request      = require 'http.request'
local http_headers      = require 'http.headers'
local http_websocket    = require 'http.websocket'

local driver_mod = require 'services.http.transport.cqueues_driver'
local lua_http   = require 'services.http.transport.lua_http'
local ws_wrap    = require 'services.http.transport.websocket'
local terminate  = require 'services.http.transport.terminate'

local M = {}

local function eq(a, b, msg)
	if a ~= b then
		error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2)
	end
end

local function ok(v, msg)
	if not v then error(msg or 'assertion failed', 2) end
	return v
end

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

local function new_listener(opts)
	opts = opts or {}

	local driver = ok(driver_mod.new {
		label = opts.label or 'http-transport-real-integration',
	})

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

local function start_listener(scope, listener, driver)
	ok(driver:start(scope), 'driver should start')
	ok(listener:start(scope), 'listener should start')
	ok(fibers.perform(listener:listen_op()), 'listener:listen should succeed')

	local family, addr, port = listener:_raw_server_for_test():localname()
	ok(family, 'server:localname should return a family')
	ok(addr, 'server:localname should return an address')
	ok(type(port) == 'number' and port > 0, 'server should bind an ephemeral TCP port')

	return port
end

local function run_http_client(driver, uri, body, method)
	return fibers.perform(driver:run_op('real-http-client', function ()
		local req = http_request.new_from_uri(uri)
		if method then req.headers:upsert(':method', method) end
		if body ~= nil then
			req.headers:upsert(':method', method or 'POST')
			req:set_body(body)
		end

		local headers, stream = assert(req:go(5))
		local response_body = assert(stream:get_body_as_string(5))
		return headers:get(':status'), response_body
	end))
end


function M.test_real_transport_terminate_server_helper_closes_lua_http_server()
	fibers.run(function (scope)
		local listener, driver = new_listener({ label = 'http-transport-real-terminate-helper' })
		local port = start_listener(scope, listener, driver)
		ok(type(port) == 'number' and port > 0)
		ok(terminate.terminate_server(listener:_raw_server_for_test(), 'helper_close'))
		listener:terminate('done')
		driver:terminate('done')
	end)
end

function M.test_real_http_get_round_trips_through_listener_context()
	fibers.run(function (scope)
		local listener, driver = new_listener()
		local port = start_listener(scope, listener, driver)

		local seen_path
		ok(scope:spawn(function ()
			local ctx = ok(fibers.perform(listener:accept_op()))
			local req_headers = ok(fibers.perform(ctx:get_headers_op()))
			seen_path = req_headers:get(':path')

			ok(fibers.perform(ctx:write_headers_op(response_headers(200, 'text/plain'))))
			ok(fibers.perform(ctx:write_body_from_string_op('hello from fibers')))
		end))

		local status, body = run_http_client(driver, http_uri(port, '/hello'))
		eq(status, '200')
		eq(body, 'hello from fibers')
		eq(seen_path, '/hello')

		listener:terminate('done')
		driver:terminate('done')
	end)
end

function M.test_real_http_post_body_is_read_and_echoed()
	fibers.run(function (scope)
		local listener, driver = new_listener()
		local port = start_listener(scope, listener, driver)

		ok(scope:spawn(function ()
			local ctx = ok(fibers.perform(listener:accept_op()))
			local req_headers = ok(fibers.perform(ctx:get_headers_op()))
			eq(req_headers:get(':method'), 'POST')

			local payload = ok(fibers.perform(ctx:read_body_as_string_op()))
			ok(fibers.perform(ctx:write_headers_op(response_headers(201, 'text/plain'))))
			ok(fibers.perform(ctx:write_body_from_string_op('echo:' .. payload)))
		end))

		local status, body = run_http_client(driver, http_uri(port, '/upload'), 'abc123', 'POST')
		eq(status, '201')
		eq(body, 'echo:abc123')

		listener:terminate('done')
		driver:terminate('done')
	end)
end

function M.test_real_multiple_concurrent_http_requests_complete()
	fibers.run(function (scope)
		local listener, driver = new_listener()
		local port = start_listener(scope, listener, driver)
		local n = 5
		local handled = 0
		local completed = 0
		local results = {}

		for _ = 1, n do
			ok(scope:spawn(function ()
				local ctx = ok(fibers.perform(listener:accept_op()))
				local req_headers = ok(fibers.perform(ctx:get_headers_op()))
				local path = req_headers:get(':path') or '/none'
				handled = handled + 1
				ok(fibers.perform(ctx:write_headers_op(response_headers(200, 'text/plain'))))
				ok(fibers.perform(ctx:write_body_from_string_op('seen:' .. path)))
			end))
		end

		for i = 1, n do
			ok(scope:spawn(function ()
				local status, body = run_http_client(driver, http_uri(port, '/r' .. i))
				results[i] = { status = status, body = body }
				completed = completed + 1
			end))
		end

		wait_until(function () return completed == n end, 5, 'concurrent HTTP clients')

		for i = 1, n do
			eq(results[i].status, '200')
			eq(results[i].body, 'seen:/r' .. i)
		end
		eq(handled, n)

		listener:terminate('done')
		driver:terminate('done')
	end)
end

function M.test_real_websocket_echo_round_trip_uses_context_wrapper()
	fibers.run(function (scope)
		local listener, driver = new_listener()
		local port = start_listener(scope, listener, driver)

		ok(scope:spawn(function ()
			local ctx = ok(fibers.perform(listener:accept_op()))
			local req_headers = ok(fibers.perform(ctx:get_headers_op()))
			local ws = ok(fibers.perform(ws_wrap.from_context_op(ctx, req_headers, {
				websocket_module = http_websocket,
			})))
			ok(fibers.perform(ws:accept_op({})))

			local data, opcode = fibers.perform(ws:receive_op())
			ok(data, 'server WebSocket receive should return data')
			eq(opcode, 'text')

			ok(fibers.perform(ws:send_op(data .. ':echo', 'text')))
			fibers.perform(ws:close_op(1000, 'done'))
		end))

		local client_data, client_opcode = fibers.perform(driver:run_op('real-websocket-client', function ()
			local ws = assert(http_websocket.new_from_uri(ws_uri(port, '/ws')))
			assert(ws:connect(5))
			assert(ws:send('ping', 'text', 5))
			local data, opcode = assert(ws:receive(5))
			ws:close(1000, 'client_done', 5)
			return data, opcode
		end))

		eq(client_data, 'ping:echo')
		eq(client_opcode, 'text')

		listener:terminate('done')
		driver:terminate('done')
	end)
end

function M.test_real_losing_driver_run_op_aborts_before_controller_pump()
	local driver = ok(driver_mod.new { label = 'http-transport-losing-run-op' })
	local ran = false

	fibers.run(function (scope)
		local which = fibers.perform(fibers.named_choice {
			winner = fibers.always('now'),
			loser = driver:run_op('must-not-run', function ()
				ran = true
				return 'bad'
			end),
		})
		eq(which, 'winner')

		ok(driver:start(scope))
		yield_many(8)
		ok(not ran, 'aborted cqueues job must not run after losing choice')

		driver:terminate('done')
	end)
end

function M.test_real_multiple_concurrent_driver_run_ops_complete()
	local driver = ok(driver_mod.new { label = 'http-transport-concurrent-run-ops' })

	fibers.run(function (scope)
		ok(driver:start(scope))

		local n = 6
		local completed = 0
		local results = {}

		for i = 1, n do
			ok(scope:spawn(function ()
				local value, err = fibers.perform(driver:run_op('real-job-' .. i, function ()
					return i * 10
				end))
				results[i] = { value = value, err = err }
				completed = completed + 1
			end))
		end

		wait_until(function () return completed == n end, 5, 'concurrent cqueues jobs')

		for i = 1, n do
			eq(results[i].value, i * 10)
			eq(results[i].err, nil)
		end

		driver:terminate('done')
	end)
end

function M.test_real_listener_termination_wakes_pending_accept()
	fibers.run(function (scope)
		local listener, driver = new_listener()
		start_listener(scope, listener, driver)

		local got, err
		ok(scope:spawn(function ()
			got, err = fibers.perform(listener:accept_op())
		end))

		yield_many(4)
		listener:terminate('listener_closed')
		yield_many(4)

		eq(got, nil)
		eq(err, 'listener_closed')

		driver:terminate('done')
	end)
end

function M.test_real_driver_termination_wakes_pending_cqueues_job()
	fibers.run(function (scope)
		local driver = ok(driver_mod.new { label = 'http-transport-driver-termination' })
		ok(driver:start(scope))

		local result, err
		ok(scope:spawn(function ()
			result, err = fibers.perform(driver:run_op('blocked-real-cqueues-job', function ()
				local cv = cqueues_condition.new and cqueues_condition.new() or cqueues_condition()
				cv:wait()
				return 'unexpected'
			end))
		end))

		yield_many(8)
		driver:terminate('driver_stopped')
		yield_many(8)

		eq(result, nil)
		eq(err, 'driver_stopped')
	end)
end

return M
