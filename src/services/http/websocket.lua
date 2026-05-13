-- services/http/websocket.lua
-- Public WebSocket transport handle boundary above services.http.transport.

local transport_ws = require 'services.http.transport.websocket'
local op = require 'fibers.op'

local M = {}

local WebSocket = {}
WebSocket.__index = WebSocket

local ClientWebSocket = {}
ClientWebSocket.__index = ClientWebSocket

local function copy(t)
	local out = {}
	for k, v in pairs(t or {}) do out[k] = v end
	return out
end

local function raw_context(ctx)
	if ctx and type(ctx._raw_context) == 'function' then return ctx:_raw_context() end
	return ctx
end

local function notify_terminated(self, reason)
	if self._closed then return true end
	self._closed = true
	self._close_reason = reason or 'closed'
	local hooks = self._terminate_hooks or {}
	self._terminate_hooks = {}
	local hook = self._on_terminate
	self._on_terminate = nil
	if hook then pcall(hook, self, self._close_reason) end
	for _, f in ipairs(hooks) do pcall(f, self, self._close_reason) end
	return true
end

local function wrap_server(raw, opts)
	if raw == nil then return nil, 'websocket_required' end
	if type(raw) == 'table' and raw._http_public_websocket then return raw._http_public_websocket end
	local self = setmetatable({
		_raw = raw,
		_closed = false,
		_close_reason = nil,
		_on_terminate = opts and opts.on_terminate,
		_terminate_hooks = {},
	}, WebSocket)
	if type(raw) == 'table' then raw._http_public_websocket = self end
	return self
end

local function wrap_client(raw, opts)
	if raw == nil then return nil, 'websocket_required' end
	if type(raw) == 'table' and raw._http_public_client_websocket then return raw._http_public_client_websocket end
	local self = setmetatable({
		_raw = raw,
		_closed = false,
		_close_reason = nil,
		_on_terminate = opts and opts.on_terminate,
		_terminate_hooks = {},
	}, ClientWebSocket)
	if type(raw) == 'table' then raw._http_public_client_websocket = self end
	return self
end

function M.from_context_op(ctx, headers, opts)
	opts = opts or {}
	return op.guard(function ()
		local public
		local transport_opts = copy(opts)
		transport_opts.on_terminate = function (_, reason)
			if public then return public:_notify_terminated(reason) end
			local hook = opts.on_terminate
			if hook then return hook(nil, reason) end
			return true
		end
		return transport_ws.from_context_op(raw_context(ctx), headers, transport_opts):wrap(function (raw_ws, err)
			if not raw_ws then return nil, err end
			public = assert(wrap_server(raw_ws, opts))
			if ctx and type(ctx._register_server_websocket) == 'function' then
				local ok, rerr = ctx:_register_server_websocket(public)
				if ok == nil or ok == false then
					public:terminate(rerr or 'websocket_registration_failed')
					return nil, rerr or 'websocket_registration_failed'
				end
			end
			return public, nil
		end)
	end)
end

function M.connect_op(driver, args, opts)
	opts = opts or {}
	return op.guard(function ()
		local public
		local transport_opts = copy(opts)
		transport_opts.on_terminate = function (_, reason)
			if public then return public:_notify_terminated(reason) end
			local hook = opts.on_terminate
			if hook then return hook(nil, reason) end
			return true
		end
		return transport_ws.connect_op(driver, args, transport_opts):wrap(function (raw_ws, err)
			if not raw_ws then return nil, err end
			public = assert(wrap_client(raw_ws, opts))
			return public, nil
		end)
	end)
end

function WebSocket:_raw_websocket_for_test()
	return self._raw and self._raw._raw_websocket_for_test and self._raw:_raw_websocket_for_test()
end

function WebSocket:_notify_terminated(reason)
	return notify_terminated(self, reason)
end

function WebSocket:add_terminate_hook(fn)
	if type(fn) ~= 'function' then return nil, 'invalid_args' end
	if self._closed then fn(self, self._close_reason or 'closed'); return function () end end
	local hooks = self._terminate_hooks or {}
	self._terminate_hooks = hooks
	hooks[#hooks + 1] = fn
	local active = true
	return function ()
		if not active then return end
		active = false
		for i, h in ipairs(hooks) do
			if h == fn then table.remove(hooks, i); break end
		end
	end
end


function WebSocket:context()
	local raw_ctx = self._raw and self._raw.context and self._raw:context()
	return raw_ctx
end

function WebSocket:is_closed()
	return self._closed or (self._raw and self._raw:is_closed())
end

function WebSocket:why()
	return self._close_reason or (self._raw and self._raw:why())
end

function WebSocket:accept_op(options)
	return self._raw:accept_op(options)
end

function WebSocket:receive_op()
	return self._raw:receive_op()
end

function WebSocket:send_op(data, opcode)
	return self._raw:send_op(data, opcode)
end

function WebSocket:send_ping_op(data)
	return self._raw:send_ping_op(data)
end

function WebSocket:send_pong_op(data)
	return self._raw:send_pong_op(data)
end

function WebSocket:close_op(code, reason)
	return self._raw:close_op(code, reason):wrap(function (ok, err)
		self:_notify_terminated(reason or err or 'closed')
		return ok, err
	end)
end

function WebSocket:terminate(reason)
	if self._closed then return true end
	if self._raw and self._raw.terminate then self._raw:terminate(reason or 'closed') end
	return self:_notify_terminated(reason or 'closed')
end

function ClientWebSocket:_raw_websocket_for_test()
	return self._raw and self._raw._raw_websocket_for_test and self._raw:_raw_websocket_for_test()
end

function ClientWebSocket:_notify_terminated(reason)
	return notify_terminated(self, reason)
end

function ClientWebSocket:add_terminate_hook(fn)
	if type(fn) ~= 'function' then return nil, 'invalid_args' end
	if self._closed then fn(self, self._close_reason or 'closed'); return function () end end
	local hooks = self._terminate_hooks or {}
	self._terminate_hooks = hooks
	hooks[#hooks + 1] = fn
	local active = true
	return function ()
		if not active then return end
		active = false
		for i, h in ipairs(hooks) do
			if h == fn then table.remove(hooks, i); break end
		end
	end
end


function ClientWebSocket:is_closed()
	return self._closed or (self._raw and self._raw:is_closed())
end

function ClientWebSocket:why()
	return self._close_reason or (self._raw and self._raw:why())
end

function ClientWebSocket:receive_op()
	return self._raw:receive_op()
end

function ClientWebSocket:send_op(data, opcode)
	return self._raw:send_op(data, opcode)
end

function ClientWebSocket:send_ping_op(data)
	return self._raw:send_ping_op(data)
end

function ClientWebSocket:send_pong_op(data)
	return self._raw:send_pong_op(data)
end

function ClientWebSocket:close_op(code, reason)
	return self._raw:close_op(code, reason):wrap(function (ok, err)
		self:_notify_terminated(reason or err or 'closed')
		return ok, err
	end)
end

function ClientWebSocket:terminate(reason)
	if self._closed then return true end
	if self._raw and self._raw.terminate then self._raw:terminate(reason or 'closed') end
	return self:_notify_terminated(reason or 'closed')
end

M.wrap_server = wrap_server
M.wrap_client = wrap_client
M.WebSocket = WebSocket
M.ClientWebSocket = ClientWebSocket
return M
