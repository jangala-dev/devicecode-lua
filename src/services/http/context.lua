-- services/http/context.lua
-- Public server-side HTTP context handle.
--
-- The transport context is deliberately kept behind this wrapper.  Consumers get
-- Fibers-native Ops and an immediate termination path; lua-http/cqueues details
-- stay below services/http/transport.

local M = {}
local HttpContext = {}
HttpContext.__index = HttpContext

local function registry_id_for(raw)
	local id = (raw and type(raw.id) == 'function') and raw:id() or tostring(raw)
	return 'ctx' .. tostring(id)
end

function M.wrap(raw, opts)
	if raw == nil then return nil, 'context_required' end
	if type(raw) == 'table' and raw._http_public_context then return raw._http_public_context end

	opts = opts or {}
	local self = setmetatable({
		_raw = raw,
		_listener = opts.listener,
		_registry_id = opts.registry_id or registry_id_for(raw),
		_on_terminate = opts.on_terminate,
		_on_server_websocket = opts.on_server_websocket,
		_closed = false,
	}, HttpContext)

	if type(raw) == 'table' then raw._http_public_context = self end
	return self
end

function HttpContext:_raw_context()
	return self._raw
end

function HttpContext:_raw_stream_for_test()
	return self._raw and self._raw._raw_stream_for_test and self._raw:_raw_stream_for_test()
end

function HttpContext:_raw_server_for_test()
	return self._raw and self._raw._raw_server_for_test and self._raw:_raw_server_for_test()
end

function HttpContext:id()
	return self._raw:id()
end

function HttpContext:registry_id()
	return self._registry_id
end

function HttpContext:is_closed()
	return self._closed or self._raw:is_closed()
end

function HttpContext:why()
	return self._raw:why()
end

function HttpContext:run_stream_op(label, fn, opts)
	return self._raw:run_stream_op(label, function (stream)
		return fn(stream, self)
	end, opts)
end

function HttpContext:get_headers_op()
	return self._raw:get_headers_op()
end

function HttpContext:read_chunk_op(max)
	return self._raw:read_chunk_op(max)
end

function HttpContext:read_chars_op(n)
	return self._raw:read_chars_op(n)
end

function HttpContext:read_body_as_string_op()
	return self._raw:read_body_as_string_op()
end

function HttpContext:write_headers_op(headers, end_stream)
	return self._raw:write_headers_op(headers, end_stream)
end

function HttpContext:write_chunk_op(chunk, end_stream)
	return self._raw:write_chunk_op(chunk, end_stream)
end

function HttpContext:write_body_from_string_op(str)
	return self._raw:write_body_from_string_op(str)
end

function HttpContext:peername_op()
	return self._raw:peername_op()
end

function HttpContext:localname_op()
	return self._raw:localname_op()
end

function HttpContext:checktls_op()
	return self._raw:checktls_op()
end

function HttpContext:connection_version_op()
	return self._raw:connection_version_op()
end

function HttpContext:write_continue_op()
	return self._raw:write_continue_op()
end

function HttpContext:unget_op(str)
	return self._raw:unget_op(str)
end

function HttpContext:shutdown_op()
	return self._raw:shutdown_op()
end

function HttpContext:_notify_terminated(reason)
	if self._closed then return true end
	self._closed = true
	local hook = self._on_terminate
	self._on_terminate = nil
	if hook then hook(self, reason or (self._raw and self._raw:why()) or 'closed') end
	return true
end

function HttpContext:terminate(reason)
	local ok, err = self._raw:terminate(reason)
	self:_notify_terminated(reason or (self._raw and self._raw:why()) or 'closed')
	return ok, err
end

function HttpContext:_register_server_websocket(ws)
	local hook = self._on_server_websocket
	if hook then return hook(self, ws) end
	return true
end

function HttpContext:upgrade_websocket_op(headers, opts)
	return require('services.http.websocket').from_context_op(self, headers, opts)
end

M.HttpContext = HttpContext
M.registry_id_for = registry_id_for
return M
