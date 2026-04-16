-- services/fabric/transport_uart.lua
--
-- UART-backed framed transport adapter.
--
-- This adapter matches the current HAL UART capability contract:
--   * control call 'open' returns Reply.ok=true with a real fibers Stream in Reply.reason
--   * the returned Stream is then used directly for framed reads/writes in-process
--   * stream closure is the normal close path; the UART driver wraps close_op() so
--     closing the stream unregisters the active UART stream and emits close state/events

local op        = require 'fibers.op'
local sleep     = require 'fibers.sleep'
local runtime   = require 'fibers.runtime'
local cap_sdk   = require 'services.hal.sdk.cap'
local cap_args  = require 'services.hal.types.capability_args'

local M = {}

local Transport = {}
Transport.__index = Transport

local function is_stream(x)
	return type(x) == 'table' and type(x.read_line_op) == 'function' and type(x.write_op) == 'function'
end

local function build_open_opts(transport)
	local supplied = transport and transport.open_opts or nil
	if supplied ~= nil then
		return supplied
	end

	local read  = true
	local write = true
	if transport and transport.read ~= nil then read = not not transport.read end
	if transport and transport.write ~= nil then write = not not transport.write end

	local opts, err = cap_args.UARTOpenOpts(read, write)
	if not opts then return nil, err end
	return opts, nil
end

local function extract_stream(reply, err)
	if not reply then
		return nil, err or 'call_failed'
	end
	if reply.ok ~= true then
		return nil, tostring(reply.reason or err or 'transport_error')
	end
	local stream = reply.reason
	if not is_stream(stream) then
		return nil, 'uart_open did not return a stream'
	end
	return stream, nil
end

local function close_stream(stream)
	if not stream or type(stream.close_op) ~= 'function' then
		return true, nil
	end

	local ev = stream:close_op()
	if runtime.current_fiber() then
		return ev and require('fibers.performer').perform(ev) or true, nil
	end
	return op.perform_raw(ev)
end

function Transport:close()
	if self._closed then return true, nil end
	self._closed = true

	local stream = self._stream
	self._stream = nil
	return close_stream(stream)
end

function Transport:read_line_op(timeout)
	if self._closed or not self._stream then
		return op.always(nil, 'closed')
	end

	local read_ev = self._stream:read_line_op({
		terminator = self._terminator,
		keep_terminator = false,
	}):wrap(function(line, err)
		if line ~= nil then return line, nil end
		if err ~= nil then return nil, err end
		return nil, 'closed'
	end)

	if timeout == nil then
		return read_ev
	end

	return op.choice(
		read_ev,
		sleep.sleep_op(timeout):wrap(function() return nil, 'timeout' end)
	)
end

function Transport:write_line_op(line)
	if self._closed or not self._stream then
		return op.always(nil, 'closed')
	end
	if type(line) ~= 'string' then
		return op.always(nil, 'line_must_be_string')
	end

	local out = line
	if self._terminator ~= '' then
		out = out .. self._terminator
	end

	return self._stream:write_op(out):wrap(function(n, err)
		if n == nil then return nil, err or 'write_failed' end
		return true, nil
	end)
end

local function open_transport(conn, link_id, cfg)
	cfg = cfg or {}
	local transport = cfg.transport or cfg.uart or {}
	local uart_id = transport.id or cfg.capability_id or cfg.uart_id or link_id
	local class = transport.class or 'uart'
	local open_verb = transport.open_verb or 'open'
	local term = transport.terminator
	if term == nil then term = '\n' end

	local cap = cap_sdk.new_cap_ref(conn, class, uart_id)
	local open_opts, oerr = build_open_opts(transport)
	if not open_opts then
		return nil, oerr or 'invalid_uart_open_opts'
	end

	local reply, err = cap:call_control(open_verb, open_opts)
	local stream, ferr = extract_stream(reply, err)
	if not stream then
		return nil, ferr
	end

	return setmetatable({
		_cap = cap,
		_stream = stream,
		_link_id = link_id,
		_opts = transport,
		_terminator = term,
		_closed = false,
	}, Transport), nil
end

local function wrap_custom_transport(link_id, cfg, obj)
	if type(obj) ~= 'table' then
		return obj
	end
	if type(obj.read_line_op) == 'function' and type(obj.write_line_op) == 'function' then
		return obj
	end
	if is_stream(obj) then
		local transport = (cfg and cfg.transport) or cfg and cfg.uart or {}
		local term = transport and transport.terminator
		if term == nil then term = '\n' end
		return setmetatable({
			_cap = nil,
			_stream = obj,
			_link_id = link_id,
			_opts = transport,
			_terminator = term,
			_closed = false,
		}, Transport)
	end
	return obj
end

function M.open(conn, link_id, cfg)
	if cfg and cfg.transport and type(cfg.transport.open) == 'function' then
		local obj, err = cfg.transport.open(conn, link_id, cfg)
		if not obj then return nil, err end
		return wrap_custom_transport(link_id, cfg, obj), nil
	end
	return open_transport(conn, link_id, cfg)
end

M.Transport = Transport

return M
