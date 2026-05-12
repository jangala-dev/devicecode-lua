-- services/fabric/hal_transport.lua
--
-- HAL-backed Fabric JSONL transport adapter.
--
-- Core Fabric consumes frame transports. This module adapts line/stream HAL
-- sessions to the fabric-jsonl/1 frame transport contract, and can open such a
-- session through a raw host HAL capability.

local fibers = require 'fibers'
local op     = require 'fibers.op'
local sleep  = require 'fibers.sleep'

local protocol = require 'services.fabric.protocol'
local resource = require 'devicecode.support.resource'
local cap_sdk  = require 'services.hal.sdk.cap'
local cap_args = require 'services.hal.types.capability_args'

local M = {}

local DEFAULT_CAP_READY_TIMEOUT_S = 5.0

--------------------------------------------------------------------------------
-- JSONL transport wrapper
--------------------------------------------------------------------------------

local Transport = {}
Transport.__index = Transport

local function has_terminate_contract(x)
	return type(x) == 'table' and type(x.terminate) == 'function'
end

local function has_line_contract(x)
	return type(x) == 'table'
		and type(x.read_line_op) == 'function'
		and type(x.write_line_op) == 'function'
		and has_terminate_contract(x)
end

local function has_stream_contract(x)
	return type(x) == 'table'
		and type(x.read_line_op) == 'function'
		and type(x.write_op) == 'function'
		and has_terminate_contract(x)
end

function M.is_transport_session(x)
	return has_line_contract(x) or has_stream_contract(x)
end

local function normalise_bool(ok, err, fallback)
	if ok == true then return true, nil end
	return nil, err or fallback
end

local function write_bytes_result(n, err)
	if n == nil then
		return nil, err or 'write_failed'
	end
	return true, nil
end

--- Wrap a raw HAL line/stream session as a fabric-jsonl/1 frame transport.
---
--- Accepted raw shapes:
---   * read_line_op / write_line_op
---   * read_line_op / write_op
function M.wrap_transport(session, opts)
	opts = opts or {}

	if type(session) ~= 'table' then
		return nil, 'transport_session_is_not_table'
	end

	local mode
	if has_line_contract(session) then
		mode = 'line'
	elseif has_stream_contract(session) then
		mode = 'stream'
	else
		return nil, 'transport_session_is_not_jsonl_line_like'
	end

	local terminator = opts.terminator
	if terminator == nil then terminator = '\n' end
	if type(terminator) ~= 'string' then
		return nil, 'invalid_transport_terminator'
	end

	return setmetatable({
		_session    = session,
		_mode       = mode,
		_terminator = terminator,
		_closed     = false,
	}, Transport), nil
end

M.wrap = M.wrap_transport

function Transport:_take_session()
	local session = self._session
	self._session = nil
	return session
end

function Transport:_active_session_op()
	if self._closed or self._session == nil then
		return nil, op.always(nil, 'closed')
	end
	return self._session, nil
end

function Transport:read_line_op()
	return op.guard(function ()
		local session, closed = self:_active_session_op()
		if session == nil then return closed end

		return session:read_line_op({
			terminator = self._terminator,
			keep_terminator = false,
		}):wrap(function (line, err)
			if line ~= nil then return line, nil end
			return nil, err or 'closed'
		end)
	end)
end

function Transport:write_line_op(line)
	return op.guard(function ()
		local session, closed = self:_active_session_op()
		if session == nil then return closed end

		if type(line) ~= 'string' then
			return op.always(nil, 'line_must_be_string')
		end

		if self._mode == 'line' then
			return session:write_line_op(line):wrap(function (ok, err)
				return normalise_bool(ok, err, 'write_failed')
			end)
		end

		if self._terminator ~= '' then
			line = line .. self._terminator
		end

		return session:write_op(line):wrap(write_bytes_result)
	end)
end

function Transport:read_frame_op()
	return self:read_line_op():wrap(function (line, err)
		if line == nil then
			return nil, err
		end
		return protocol.decode_line(line)
	end)
end

function Transport:write_frame_op(frame)
	return op.guard(function ()
		local session, closed = self:_active_session_op()
		if session == nil then return closed end

		local checked, verr = protocol.validate(frame)
		if checked == nil then
			return op.always(nil, verr)
		end

		local line, enc_err = protocol.encode_line(checked)
		if line == nil then
			return op.always(nil, enc_err)
		end

		return self:write_line_op(line)
	end)
end

function Transport:flush_op()
	return op.guard(function ()
		local session, closed = self:_active_session_op()
		if session == nil then
			return op.always(true, nil)
		end

		if type(session.flush_op) ~= 'function' then
			return op.always(true, nil)
		end

		return session:flush_op():wrap(function (ok, err)
			return normalise_bool(ok, err, 'flush_failed')
		end)
	end)
end

function Transport:terminate(reason)
	if self._closed then
		return true, nil
	end

	self._closed = true
	return resource.terminate(self:_take_session(), reason)
end

function Transport:close_op(reason)
	return op.guard(function ()
		if self._closed then
			return op.always(true, nil)
		end

		self._closed = true
		local session = self:_take_session()

		if session ~= nil and type(session.close_op) == 'function' then
			return session:close_op(reason):wrap(function (ok, err)
				return normalise_bool(ok, err, 'close_failed')
			end)
		end

		return op.always(resource.terminate(session, reason))
	end)
end

M.Transport = Transport

--------------------------------------------------------------------------------
-- HAL open adapter
--------------------------------------------------------------------------------

local function require_transport_cfg(cfg, level)
	if type(cfg) ~= 'table' then
		error('fabric.hal_transport.open_transport_op: transport config table required', (level or 1) + 1)
	end

	for _, field in ipairs({ 'source', 'class', 'id' }) do
		if type(cfg[field]) ~= 'string' or cfg[field] == '' then
			error('fabric.hal_transport.open_transport_op: transport.' .. field .. ' must be a non-empty string', (level or 1) + 1)
		end
	end

	return cfg
end

local function unwrap_open_transport_reply(reply, err)
	if reply == nil then
		return nil, err or 'transport_open_failed'
	end

	if type(reply) ~= 'table' then
		return nil, 'transport_open_reply_must_be_table'
	end

	if reply.ok ~= true then
		return nil, tostring(reply.reason or err or 'transport_open_failed')
	end

	if type(reply.reason) ~= 'table' then
		return nil, 'transport_open_reply_reason_must_be_table'
	end

	local session = reply.reason.session
	if session == nil then
		return nil, 'transport_open_reply_missing_session'
	end

	return session, nil
end

local function normalise_open_opts(transport_cfg)
	if transport_cfg.class == 'uart' then
		local opts, err = cap_args.new.UARTOpenOpts(transport_cfg.open_opts or {})
		if not opts then return nil, err or 'invalid uart open opts' end
		return opts, nil
	end

	if transport_cfg.open_opts == nil then return {}, nil end
	if type(transport_cfg.open_opts) ~= 'table' then
		return nil, 'transport.open_opts must be a table'
	end
	return transport_cfg.open_opts, nil
end

local function cap_route(transport_cfg)
	return ('raw/host/%s/cap/%s/%s'):format(
		tostring(transport_cfg.source),
		tostring(transport_cfg.class),
		tostring(transport_cfg.id)
	)
end

local function cap_ready_timeout_s(transport_cfg, opts)
	local v = (opts and opts.ready_timeout_s)
		or transport_cfg.ready_timeout_s
		or transport_cfg.cap_ready_timeout_s
		or DEFAULT_CAP_READY_TIMEOUT_S
	if type(v) ~= 'number' or v <= 0 then return DEFAULT_CAP_READY_TIMEOUT_S end
	return v
end

local function wait_for_transport_capability_op(conn, transport_cfg, opts)
	if opts and opts.wait_ready == false then return op.always(true, nil) end
	if transport_cfg.wait_ready == false then return op.always(true, nil) end

	return fibers.run_scope_op(function (scope)
		local listener = cap_sdk.new_raw_host_cap_listener(
			conn,
			transport_cfg.source,
			transport_cfg.class,
			transport_cfg.id
		)
		scope:finally(function ()
			listener:terminate('fabric transport capability wait closed')
		end)

		local which, ref, err = fibers.perform(fibers.named_choice({
			cap = listener:wait_for_cap_op(),
			timeout = sleep.sleep_op(cap_ready_timeout_s(transport_cfg, opts)):wrap(function ()
				return nil, 'timeout'
			end),
		}))

		if which == 'timeout' then
			return nil, 'transport capability not ready: ' .. cap_route(transport_cfg)
		end
		if ref == nil then
			return nil, err or ('transport capability unavailable: ' .. cap_route(transport_cfg))
		end
		return true, nil
	end):wrap(function (st, rep, ok, err)
		if st ~= 'ok' then
			return nil, tostring(err or rep or st)
		end
		if ok ~= true then
			return nil, err or ('transport capability unavailable: ' .. cap_route(transport_cfg))
		end
		return true, nil
	end)
end

function M.open_transport_op(conn, transport_cfg, transport_session, opts)
	transport_cfg = require_transport_cfg(transport_cfg, 2)
	opts = opts or {}

	return op.guard(function ()
		if transport_session ~= nil then
			local transport, terr = M.wrap_transport(transport_session, transport_cfg)
			if not transport then
				return op.always(nil, terr or 'transport_wrap_failed')
			end
			return op.always(transport, nil)
		end

		if conn == nil then
			return op.always(nil, 'transport_open_requires_bus_connection')
		end

		local open_opts, open_opts_err = normalise_open_opts(transport_cfg)
		if not open_opts then
			return op.always(nil, open_opts_err)
		end

		return fibers.run_scope_op(function ()
			local ready, ready_err = fibers.perform(wait_for_transport_capability_op(conn, transport_cfg, opts))
			if ready ~= true then
				return nil, ready_err or ('transport capability unavailable: ' .. cap_route(transport_cfg))
			end

			local cap = cap_sdk.new_raw_host_cap_ref(
				conn,
				transport_cfg.source,
				transport_cfg.class,
				transport_cfg.id
			)

			local reply, call_err = fibers.perform(cap:call_control_op(
				transport_cfg.open_verb or 'open',
				open_opts
			))

			local session, unwrap_err = unwrap_open_transport_reply(reply, call_err)
			if not session then
				return nil, unwrap_err
			end

			local transport, wrap_err = M.wrap_transport(session, transport_cfg)
			if not transport then
				return nil, wrap_err or 'transport_wrap_failed'
			end
			return transport, nil
		end):wrap(function (st, rep, transport, err)
			if st ~= 'ok' then
				return nil, tostring(err or rep or st)
			end
			return transport, err
		end)
	end)
end

function M.open_transport(conn, transport_cfg, transport_session, opts)
	return fibers.perform(M.open_transport_op(conn, transport_cfg, transport_session, opts))
end

M.unwrap_open_transport_reply = unwrap_open_transport_reply
M.wait_for_transport_capability_op = wait_for_transport_capability_op

return M
