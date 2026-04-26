-- services/fabric/transport_stream.lua
--
-- Stream-backed framed transport adapter.
--
-- Responsibilities:
--   * normalise the current HAL UART capability contract into a transport with:
--       - read_line_op(...)
--       - write_line_op(...)
--   * expose open_op(...) and close_op(...) for composition
--
-- This adapter does not own reconnection, handshake, or restart policy.
--
-- DeviceCode always runs inside fibres, so the blocking wrappers simply
-- perform the corresponding ops.
--
-- Important:
--   * open_op(...) and close_op(...) preserve the ordinary API shape
--       - open_op  -> transport|nil, err|nil
--       - close_op -> ok|nil, err|nil
--     even though they are implemented using scope run ops internally.
--
-- Design notes:
--   * capability acquisition is treated as a bounded scoped work unit
--   * once open, the adapter is just a thin line-oriented façade over the
--     underlying stream

local fibers    = require 'fibers'
local sleep     = require 'fibers.sleep'
local scope     = require 'fibers.scope'
local cap_sdk   = require 'services.hal.sdk.cap'
local cap_args  = require 'services.hal.types.capability_args'

local M = {}

local Transport = {}
Transport.__index = Transport

local function is_stream(x)
	return type(x) == 'table'
		and type(x.read_line_op) == 'function'
		and type(x.write_op) == 'function'
end

local function build_open_opts(transport)
	local supplied = transport and transport.open_opts or nil
	if supplied ~= nil then
		return supplied
	end

	local read = true
	local write = true
	if transport and transport.read ~= nil then read = not not transport.read end
	if transport and transport.write ~= nil then write = not not transport.write end

	local ctor = cap_args and cap_args.new and cap_args.new.UARTOpenOpts
	if type(ctor) ~= 'function' then
		return nil, 'UARTOpenOpts constructor unavailable'
	end

	local opts, err = ctor(read, write)
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

-- Wrap a scope run op while preserving the ordinary transport API shape:
--   * ok path      -> original return values
--   * cancelled    -> re-raise cancellation sentinel
--   * failed       -> re-raise primary error
local function preserve_api(ev, fallback_err)
	return ev:wrap(function(st, _report, ...)
		if st == 'ok' then
			return ...
		end

		local primary = ...
		if st == 'cancelled' then
			error(scope.cancelled(primary), 0)
		end

		error(primary or fallback_err or 'transport_failed', 0)
	end)
end

local function close_stream_blocking(stream)
	if not stream or type(stream.close_op) ~= 'function' then
		return true, nil
	end
	return fibers.perform(stream:close_op())
end

function Transport:_close_blocking()
	if self._closed then
		return true, nil
	end
	self._closed = true

	local stream = self._stream
	self._stream = nil
	return close_stream_blocking(stream)
end

function Transport:close_op()
	return preserve_api(
		fibers.run_scope_op(function()
			return self:_close_blocking()
		end),
		'transport_close_failed'
	)
end

function Transport:close()
	return fibers.perform(self:close_op())
end

function Transport:read_line_op(timeout)
	if self._closed or not self._stream then
		return fibers.always(nil, 'closed')
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

	local deadline = fibers.now() + timeout

	return fibers.choice(
		read_ev,
		sleep.sleep_until_op(deadline):wrap(function()
			return nil, 'timeout'
		end)
	)
end

function Transport:write_line_op(line)
	if self._closed or not self._stream then
		return fibers.always(nil, 'closed')
	end
	if type(line) ~= 'string' then
		return fibers.always(nil, 'line_must_be_string')
	end

	local out = line
	if self._terminator ~= '' then
		out = out .. self._terminator
	end

	return self._stream:write_op(out):wrap(function(n, err)
		if n == nil then
			return nil, err or 'write_failed'
		end
		return true, nil
	end)
end

local function open_transport_blocking(conn, link_id, cfg)
	cfg = cfg or {}
	local transport = cfg.transport or {}
	local uart_id = transport.id or link_id
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
		local transport = (cfg and cfg.transport) or {}
		local term = transport.terminator
		if term == nil then term = '\n' end
		return setmetatable({
			_cap = nil,
			_stream = obj,
			_link_id = link_id,
			_opts = transport,
			_terminator = term,
			_terminated = false,
			_closed = false,
		}, Transport)
	end
	return obj
end

local function open_blocking(conn, link_id, cfg)
	if cfg and cfg.transport and type(cfg.transport.open) == 'function' then
		local obj, err = cfg.transport.open(conn, link_id, cfg)
		if not obj then return nil, err end
		return wrap_custom_transport(link_id, cfg, obj), nil
	end
	return open_transport_blocking(conn, link_id, cfg)
end

function M.open_op(conn, link_id, cfg)
	return preserve_api(
		fibers.run_scope_op(function()
			return open_blocking(conn, link_id, cfg)
		end),
		'transport_open_failed'
	)
end

function M.open(conn, link_id, cfg)
	return fibers.perform(M.open_op(conn, link_id, cfg))
end

M.Transport = Transport

return M
