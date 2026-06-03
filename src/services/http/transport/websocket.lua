-- services/http/transport/websocket.lua
--
-- Fibers-facing WebSocket wrapper for lua-http WebSocket objects.
-- Underlying WebSocket methods run through the owning HttpContext command loop,
-- so service code sees Ops and does not depend on cqueues callbacks.

local op = require 'fibers.op'
local terminate = require 'services.http.transport.terminate'
local headers_mod = require 'services.http.headers'
local safe = require 'coxpcall'

local M = {}

local WebSocket = {}
WebSocket.__index = WebSocket

local function websocket_module(opts)
	if opts and opts.websocket_module then return opts.websocket_module end
	local ok, mod = pcall(require, 'http.websocket')
	if not ok then return nil, mod end
	return mod
end

local function apply_headers(ws, fields)
	if fields == nil then return true end
	local headers = ws and ws.headers
	if headers == nil then return nil, 'websocket_headers_not_supported' end
	for _, pair in ipairs(headers_mod.to_pairs(fields)) do
		local k, v = tostring(pair[1]), tostring(pair[2] or '')
		if type(headers.append) == 'function' then headers:append(k, v)
		elseif type(headers.upsert) == 'function' then headers:upsert(k, v)
		elseif type(headers.set) == 'function' then headers:set(k, v)
		else return nil, 'websocket_headers_not_supported' end
	end
	return true
end

local function wrap(ctx, ws, opts)
	local self = setmetatable({
		_ctx = ctx,
		_ws = ws,
		_closed = false,
		_close_reason = nil,
		_on_terminate = opts and opts.on_terminate,
	}, WebSocket)
	if type(ctx) == 'table' then ctx._http_transport_websocket = self end
	return self
end

function M.from_context_op(ctx, headers, opts)
	opts = opts or {}
	return op.guard(function ()
		local websocket, err = websocket_module(opts)
		if not websocket then return op.always(nil, err) end

		return ctx:run_stream_op('websocket.new_from_stream', function (stream)
			return websocket.new_from_stream(stream, headers)
		end):wrap(function (ws, werr)
			if not ws then return nil, werr or 'not_websocket' end
			return wrap(ctx, ws, opts), nil
		end)
	end)
end

function WebSocket:_raw_websocket_for_test() return self._ws end
function WebSocket:context() return self._ctx end

function WebSocket:_notify_terminated(reason)
	if self._closed then return true end
	self._closed = true
	self._close_reason = reason or 'closed'
	local hook = self._on_terminate
	self._on_terminate = nil
	if hook then safe.pcall(hook, self, self._close_reason) end
	return true
end

function WebSocket:is_closed()
	return self._closed or (self._ctx and self._ctx:is_closed())
end

function WebSocket:why()
	return self._close_reason or (self._ctx and self._ctx:why())
end

function WebSocket:accept_op(options)
	return self._ctx:run_stream_op('websocket.accept', function ()
		return self._ws:accept(options or {})
	end)
end

function WebSocket:receive_op()
	return self._ctx:run_stream_op('websocket.receive', function ()
		return self._ws:receive()
	end)
end

function WebSocket:send_op(data, opcode)
	return self._ctx:run_stream_op('websocket.send', function ()
		return self._ws:send(data, opcode)
	end)
end

function WebSocket:send_ping_op(data)
	return self._ctx:run_stream_op('websocket.send_ping', function ()
		return self._ws:send_ping(data)
	end)
end

function WebSocket:send_pong_op(data)
	return self._ctx:run_stream_op('websocket.send_pong', function ()
		return self._ws:send_pong(data)
	end)
end

function WebSocket:close_op(code, reason)
	return self._ctx:run_stream_op('websocket.close', function ()
		return self._ws:close(code, reason)
	end):wrap(function (ok, err)
		self:_notify_terminated(reason or err or 'closed')
		return ok, err
	end)
end

--- Immediate termination path for finalisers.  This is not a graceful protocol
--- close; graceful close belongs in close_op() inside a worker scope.
function WebSocket:terminate(reason)
	if self._closed then return true end
	local why = reason or 'closed'
	if self._ctx then self._ctx:terminate(why) end
	return self:_notify_terminated(why)
end

-- Client-side WebSocket transport --------------------------------------------

local ClientWebSocket = {}
ClientWebSocket.__index = ClientWebSocket

local function wrap_client(driver, ws, opts)
	return setmetatable({
		_driver = driver,
		_ws = ws,
		_closed = false,
		_close_reason = nil,
		_on_terminate = opts and opts.on_terminate,
	}, ClientWebSocket)
end

function M.connect_op(driver, args, opts)
	opts = opts or {}
	args = args or {}
	return op.guard(function ()
		if not driver or type(driver.run_op) ~= 'function' then
			return op.always(nil, 'driver_required')
		end
		local websocket, werr = websocket_module(opts)
		if not websocket then return op.always(nil, werr) end
		if type(args.uri) ~= 'string' then return op.always(nil, 'invalid_args') end

		local active = { ws = nil }
		return driver:run_op('http.websocket.connect', function ()
			local ws, err = websocket.new_from_uri(args.uri)
			if not ws then return nil, err end
			active.ws = ws
			local hok, herr = apply_headers(ws, args.headers)
			if hok ~= true then return nil, herr end
			local ok, cerr = ws:connect(opts.backend_timeout)
			if not ok then return nil, cerr end
			return ws
		end, {
			on_active_abort = function (reason)
				if active.ws then
					terminate.terminate_websocket(active.ws, reason or 'websocket_connect_aborted')
				elseif driver and driver.terminate then
					driver:terminate(reason or 'websocket_connect_aborted')
				end
			end,
		}):wrap(function (ws, err)
			if not ws then return nil, err end
			return wrap_client(driver, ws, opts), nil
		end)
	end)
end

function ClientWebSocket:_raw_websocket_for_test() return self._ws end
function ClientWebSocket:is_closed() return self._closed end
function ClientWebSocket:why() return self._close_reason end

function ClientWebSocket:_run(label, fn)
	if self._closed then return op.always(nil, self._close_reason or 'closed') end
	return self._driver:run_op(label, fn, {
		on_active_abort = function (reason)
			self:terminate(reason or 'websocket_op_aborted')
		end,
	})
end

function ClientWebSocket:receive_op()
	return self:_run('http.websocket.receive', function ()
		return self._ws:receive()
	end)
end

function ClientWebSocket:send_op(data, opcode)
	return self:_run('http.websocket.send', function ()
		return self._ws:send(data, opcode)
	end)
end

function ClientWebSocket:send_ping_op(data)
	return self:_run('http.websocket.ping', function ()
		return self._ws:send_ping(data)
	end)
end

function ClientWebSocket:send_pong_op(data)
	return self:_run('http.websocket.pong', function ()
		return self._ws:send_pong(data)
	end)
end

function ClientWebSocket:close_op(code, reason)
	return self:_run('http.websocket.close', function ()
		return self._ws:close(code, reason)
	end):wrap(function (ok, err)
		self:_notify_terminated(reason or err or 'closed')
		return ok, err
	end)
end

function ClientWebSocket:_notify_terminated(reason)
	if self._closed then return true end
	self._closed = true
	self._close_reason = reason or 'closed'
	local hook = self._on_terminate
	self._on_terminate = nil
	if hook then safe.pcall(hook, self, self._close_reason) end
	return true
end

function ClientWebSocket:terminate(reason)
	if self._closed then return true end
	local why = reason or 'closed'
	terminate.terminate_websocket(self._ws, why)
	return self:_notify_terminated(why)
end

M.ClientWebSocket = ClientWebSocket

M.WebSocket = WebSocket

return M
