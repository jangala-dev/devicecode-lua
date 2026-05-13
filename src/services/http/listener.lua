-- services/http/listener.lua
-- Public listener handle boundary above the lua-http transport listener.

local lua_http = require 'services.http.transport.lua_http'
local context_mod = require 'services.http.context'

local M = {}
local HttpListener = {}
HttpListener.__index = HttpListener

local function copy(t)
	local out = {}
	for k, v in pairs(t or {}) do out[k] = v end
	return out
end

local function make(raw, opts)
	opts = opts or {}
	local self = setmetatable({
		_raw = raw,
		_contexts = setmetatable({}, { __mode = 'k' }),
		_admitted_raw = setmetatable({}, { __mode = 'k' }),
		_events_port = opts.events_port,
	}, HttpListener)
	return self
end

function HttpListener:_wrap_context(raw)
	if raw == nil then return nil end
	local ctx = self._contexts[raw]
	if ctx == nil then
		ctx = assert(context_mod.wrap(raw, {
			listener = self,
			on_server_websocket = function (public_ctx, ws)
				return self:_emit_context_event('server_websocket_registered', public_ctx, { websocket = ws })
			end,
			on_terminate = function (public_ctx, reason)
				return self:_emit_context_event('context_terminated', public_ctx, { reason = reason })
			end,
		}))
		self._contexts[raw] = ctx
	end
	return ctx
end

function M.listen(opts)
	opts = opts or {}
	local transport_opts = copy(opts)
	transport_opts.on_context = nil
	transport_opts.on_context_admitted = nil
	transport_opts.on_context_transferred = nil
	transport_opts.on_context_terminated = nil
	transport_opts.on_server_websocket = nil

	local raw, err = lua_http.listen(transport_opts)
	if not raw then return nil, err end
	return make(raw, opts)
end


local function context_id_of(ctx)
	if ctx and type(ctx.id) == 'function' then return ctx:id() end
	if ctx and ctx.id ~= nil then return ctx.id end
	return nil
end

function HttpListener:_emit_context_event(kind, ctx, extra)
	local ev = {
		kind = kind,
		ctx = ctx,
		context_id = context_id_of(ctx),
	}
	for k, v in pairs(extra or {}) do ev[k] = v end
	local port = self._events_port
	if port and type(port.emit_required) == 'function' then
		return port:emit_required(ev, 'http_listener_context_event_report_failed')
	end

	return true
end

function HttpListener:_raw_listener()
	return self._raw
end

function HttpListener:_raw_server_for_test()
	return self._raw and self._raw:_raw_server_for_test()
end

function HttpListener:localname()
	return self._raw:localname()
end

function HttpListener:is_closed()
	return self._raw:is_closed()
end

function HttpListener:why()
	return self._raw:why()
end

function HttpListener:listen_op()
	return self._raw:listen_op()
end

function HttpListener:pump_once_op()
	return self._raw:pump_once_op()
end

function HttpListener:run()
	return self._raw:run()
end

function HttpListener:start(scope)
	return self._raw:start(scope)
end

function HttpListener:_admit_raw_context(raw_ctx)
	if raw_ctx == nil then return nil, 'context_required' end
	local ctx = self:_wrap_context(raw_ctx)
	if not self._admitted_raw[raw_ctx] then
		local ok, err = self:_emit_context_event('context_admitted', ctx)
		if ok == nil or ok == false then return nil, err or 'context_admission_report_failed' end
		self._admitted_raw[raw_ctx] = true
	end
	if ctx:is_closed() then ctx:_notify_terminated(ctx:why() or 'closed') end
	return ctx, nil
end

function HttpListener:context_admission_op()
	return self._raw:admission_op():wrap(function (raw_ctx, err)
		if raw_ctx == nil then return nil, err end
		return self:_admit_raw_context(raw_ctx)
	end)
end

function HttpListener:accept_op()
	return self._raw:accept_op():wrap(function (raw_ctx, err)
		if raw_ctx == nil then return nil, err end
		local ctx, aerr = self:_admit_raw_context(raw_ctx)
		if ctx == nil then return nil, aerr end
		local ok, terr = self:_emit_context_event('context_transferred', ctx)
		if ok == nil or ok == false then return nil, terr or 'context_transfer_report_failed' end
		return ctx, nil
	end)
end

function HttpListener:pause()
	return self._raw:pause()
end

function HttpListener:resume()
	return self._raw:resume()
end

function HttpListener:terminate(reason)
	return self._raw:terminate(reason)
end

M.listen = M.listen
M.HttpListener = HttpListener
M.Listener = HttpListener
return M
