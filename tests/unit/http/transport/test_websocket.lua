local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'
local runtime = require 'fibers.runtime'
local driver_mod = require 'services.http.transport.cqueues_driver'
local lua_http = require 'services.http.transport.lua_http'
local websocket = require 'services.http.transport.websocket'

local M = {}

local function eq(a, b, msg)
	if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end

local function ok(v, msg)
	if not v then error(msg or 'assertion failed', 2) end
end

local function yield_once()
	runtime.yield()
end

local function yield_many(n)
	for _ = 1, n do yield_once() end
end

local function yield_until(pred, msg)
	for _ = 1, 50 do
		if pred() then return true end
		yield_once()
	end
	error(msg or 'condition was not reached', 2)
end

local function fake_controller()
	local q = {}
	return {
		wrap = function (self, fn) q[#q + 1] = fn; return self end,
		step = function () local fn = table.remove(q, 1); if fn then fn() end; return true end,
		pollfd = function () return nil end,
		events = function () return '' end,
		timeout = function () return nil end,
	}
end

local function fake_condition()
	return {
		signal = function () return true end,
		wait = function () return true end,
	}
end

local function fake_server()
	return {
		pollfd = function () return nil end,
		events = function () return '' end,
		timeout = function () return nil end,
		step = function () return true end,
		close = function () return true end,
	}
end

local function listener_with(term)
	return assert(lua_http.listen {
		server = fake_server(),
		driver = assert(driver_mod.new { create_controller = false }),
		condition_factory = function () return fake_condition() end,
		context_terminator = term,
	})
end

local function fake_ws()
	return {
		calls = {},
		accept = function (self, options, timeout)
			self.calls[#self.calls+1] = {'accept', options, timeout}
			return true
		end,
		receive = function (self, timeout)
			self.calls[#self.calls+1] = {'receive', timeout}
			return 'hello', 'text'
		end,
		send = function (self, data, opcode, timeout)
			self.calls[#self.calls+1] = {'send', data, opcode, timeout}
			return true
		end,
		send_ping = function (self, data, timeout)
			self.calls[#self.calls+1] = {'ping', data, timeout}
			return true
		end,
		send_pong = function (self, data, timeout)
			self.calls[#self.calls+1] = {'pong', data, timeout}
			return true
		end,
		close = function (self, code, reason, timeout)
			self.calls[#self.calls+1] = {'close', code, reason, timeout}
			return true
		end,
	}
end

function M.test_from_context_op_constructs_websocket_inside_context()
	local listener = listener_with()
	local stream = { id = 'stream' }
	local ctx = lua_http._new_context_for_test(listener, listener:_raw_server_for_test(), stream)
	local raw = fake_ws()
	local module = {
		new_from_stream = function (s, headers)
			eq(s, stream)
			eq(headers.token, 'h')
			return raw
		end,
	}

	fibers.run(function (scope)
		local ws, err
		assert(scope:spawn(function ()
			ws, err = fibers.perform(websocket.from_context_op(ctx, { token = 'h' }, {
				websocket_module = module,
			}))
		end))
		yield_many(3)
		ok(ctx:_drain_one_for_test())
		yield_many(3)
		ok(ws, 'websocket should be returned')
		eq(err, nil)
		eq(ws:_raw_websocket_for_test(), raw)
		ws:terminate('done')
		listener:terminate('done')
	end)
end

function M.test_websocket_receive_and_send_are_context_commands()
	local listener = listener_with()
	local ctx = lua_http._new_context_for_test(listener, listener:_raw_server_for_test(), {})
	local raw = fake_ws()
	local ws = websocket.WebSocket and setmetatable({ _ctx = ctx, _ws = raw }, websocket.WebSocket) or nil
	-- Avoid reaching through the metatable from production callers; this is a unit seam.
	if not ws then error('missing WebSocket class') end

	fibers.run(function (scope)
		local data, opcode, sent
		assert(scope:spawn(function () data, opcode = fibers.perform(ws:receive_op()) end))
		yield_many(3)
		ok(ctx:_drain_one_for_test())
		yield_many(3)
		eq(data, 'hello')
		eq(opcode, 'text')

		assert(scope:spawn(function () sent = fibers.perform(ws:send_op('payload', 'text')) end))
		yield_many(3)
		ok(ctx:_drain_one_for_test())
		yield_many(3)
		eq(sent, true)
		eq(raw.calls[2][1], 'send')
		eq(raw.calls[2][2], 'payload')
		eq(raw.calls[2][3], 'text')
		eq(raw.calls[2][4], nil)

		ws:terminate('done')
		listener:terminate('done')
	end)
end

function M.test_websocket_close_op_marks_wrapper_closed()
	local listener = listener_with()
	local ctx = lua_http._new_context_for_test(listener, listener:_raw_server_for_test(), {})
	local raw = fake_ws()
	local ws = setmetatable({ _ctx = ctx, _ws = raw }, websocket.WebSocket)

	fibers.run(function (scope)
		local closed_ok
		assert(scope:spawn(function () closed_ok = fibers.perform(ws:close_op(1000, 'bye')) end))
		yield_many(3)
		ok(ctx:_drain_one_for_test())
		yield_many(3)
		eq(closed_ok, true)
		ok(ws:is_closed(), 'wrapper should be closed after close_op')
		eq(ws:why(), 'bye')
		eq(raw.calls[1][1], 'close')
		eq(raw.calls[1][2], 1000)
		eq(raw.calls[1][3], 'bye')
		listener:terminate('done')
	end)
end

function M.test_websocket_terminate_terminates_context_without_protocol_close()
	local terminated
	local listener = listener_with(function (_, reason) terminated = reason end)
	local ctx = lua_http._new_context_for_test(listener, listener:_raw_server_for_test(), {})
	local raw = fake_ws()
	local ws = setmetatable({ _ctx = ctx, _ws = raw }, websocket.WebSocket)

	ws:terminate('drop')
	ok(ws:is_closed(), 'websocket should be marked closed')
	eq(terminated, 'drop')
	eq(#raw.calls, 0, 'terminate must not perform graceful websocket close_op')
	listener:terminate('done')
end

function M.test_server_websocket_active_receive_abort_terminates_context_and_wrapper()
	local terminated_reason
	local listener = listener_with(function (_, reason) terminated_reason = reason end)
	local ctx = lua_http._new_context_for_test(listener, listener:_raw_server_for_test(), {})
	local raw = fake_ws()
	raw.receive = function (self)
		self.receive_active = true
		while terminated_reason == nil do runtime.yield() end
		return nil, 'closed'
	end
	local ws = setmetatable({ _ctx = ctx, _ws = raw }, websocket.WebSocket)
	ctx._http_transport_websocket = ws

	fibers.run(function (scope)
		local waiter = assert(scope:child())
		assert(waiter:spawn(function () fibers.perform(ws:receive_op()) end))
		assert(scope:spawn(function () ctx:_drain_one_for_test() end))
		yield_until(function () return raw.receive_active end, 'server websocket receive should become active')
		waiter:cancel('stop_waiting')
		fibers.perform(waiter:join_op())
		eq(terminated_reason, 'aborted')
		ok(ctx:is_closed(), 'active server websocket abort should close context')
		ok(ws:is_closed(), 'transport websocket wrapper should be marked closed')
		listener:terminate('done')
	end)
end

function M.test_client_websocket_active_receive_abort_terminates_websocket()
	local ctl = fake_controller()
	local drv = assert(driver_mod.new { controller = ctl })
	local raw = fake_ws()
	raw.receive = function (self)
		self.receive_active = true
		while not self.closed do runtime.yield() end
		return nil, 'closed'
	end
	raw.close = function (self, code, reason, timeout)
		self.closed = true
		self.calls[#self.calls+1] = {'close', code, reason, timeout}
		return true
	end
	local ws = setmetatable({ _driver = drv, _ws = raw }, websocket.ClientWebSocket)

	fibers.run(function (scope)
		assert(drv:start(scope))
		local waiter = assert(scope:child())
		assert(waiter:spawn(function () fibers.perform(ws:receive_op()) end))
		yield_until(function () return raw.receive_active end, 'client websocket receive should become active')
		waiter:cancel('stop_waiting')
		fibers.perform(waiter:join_op())
		ok(raw.closed, 'active client websocket abort should close raw websocket')
		ok(ws:is_closed(), 'client websocket wrapper should be marked closed')
		ok(not drv:is_closed(), 'websocket is the narrow owner; driver should survive')
		drv:terminate('done')
	end)
end

function M.test_client_websocket_active_send_abort_terminates_websocket()
	local ctl = fake_controller()
	local drv = assert(driver_mod.new { controller = ctl })
	local raw = fake_ws()
	raw.send = function (self)
		self.send_active = true
		while not self.closed do runtime.yield() end
		return true
	end
	raw.close = function (self, code, reason, timeout)
		self.closed = true
		self.calls[#self.calls+1] = {'close', code, reason, timeout}
		return true
	end
	local ws = setmetatable({ _driver = drv, _ws = raw }, websocket.ClientWebSocket)

	fibers.run(function (scope)
		assert(drv:start(scope))
		local waiter = assert(scope:child())
		assert(waiter:spawn(function () fibers.perform(ws:send_op('payload', 'text')) end))
		yield_until(function () return raw.send_active end, 'client websocket send should become active')
		waiter:cancel('stop_waiting')
		fibers.perform(waiter:join_op())
		ok(raw.closed, 'active client websocket send abort should close raw websocket')
		ok(ws:is_closed(), 'client websocket wrapper should be marked closed')
		ok(not drv:is_closed(), 'websocket is the narrow owner; driver should survive')
		drv:terminate('done')
	end)
end

return M
