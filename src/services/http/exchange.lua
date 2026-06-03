-- services/http/exchange.lua
-- Client-side HTTP exchange handle.  Stream operations run inside the cqueues
-- driver so callers compose Fibers Ops rather than lua-http timeouts.

local op = require 'fibers.op'
local headers_mod = require 'services.http.headers'
local terminate = require 'services.http.transport.terminate'
local safe = require 'coxpcall'

local M = {}
local HttpExchange = {}
HttpExchange.__index = HttpExchange

local function make(driver, response_headers, stream, opts)
	return setmetatable({
		_driver = driver,
		_headers = response_headers,
		_stream = stream,
		_closed = false,
		_close_reason = nil,
		_id = opts and opts.id,
		_on_terminate = opts and opts.on_terminate,
	}, HttpExchange)
end

function HttpExchange:response_headers()
	return self._headers
end

function HttpExchange:response_headers_table()
	return headers_mod.to_table(self._headers)
end

function HttpExchange:status()
	return headers_mod.get_one(self._headers, ':status')
end

function HttpExchange:is_closed()
	return self._closed
end

function HttpExchange:why()
	return self._close_reason
end

function HttpExchange:_stream_op(label, fn)
	if self._closed then return op.always(nil, self._close_reason or 'closed') end
	return self._driver:run_op(label, fn, {
		on_active_abort = function (reason)
			self:terminate(reason or 'exchange_op_aborted')
		end,
	})
end

function HttpExchange:read_chunk_op(_max)
	return self:_stream_op('http.exchange.read_chunk', function ()
		return self._stream:get_next_chunk()
	end)
end

function HttpExchange:read_chars_op(n)
	return self:_stream_op('http.exchange.read_chars', function ()
		return self._stream:get_body_chars(n)
	end)
end

function HttpExchange:read_body_as_string_op()
	return self:_stream_op('http.exchange.read_body_as_string', function ()
		return self._stream:get_body_as_string()
	end)
end

function HttpExchange:shutdown_op()
	return self:_stream_op('http.exchange.shutdown', function ()
		if type(self._stream.shutdown) == 'function' then return self._stream:shutdown() end
		return true
	end):wrap(function (ok, err)
		self._closed = true
		self._close_reason = err or 'closed'
		local hook = self._on_terminate
		self._on_terminate = nil
		if hook then safe.pcall(hook, self, self._close_reason) end
		return ok, err
	end)
end

function HttpExchange:terminate(reason)
	if self._closed then return true end
	self._closed = true
	self._close_reason = reason or 'closed'
	local hook = self._on_terminate
	self._on_terminate = nil
	terminate.terminate_stream(self._stream, self._close_reason)
	if hook then safe.pcall(hook, self, self._close_reason) end
	return true
end

M.make = make
M.HttpExchange = HttpExchange

return M
