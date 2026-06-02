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
local dep_failure = require 'devicecode.support.dependency_failure'
local xxhash32 = require 'shared.hash.xxhash32'

local M = {}

local DEFAULT_CAP_WAIT_TIMEOUT_S = 5.0
local DEFAULT_DRAIN_MAX_BYTES = 64 * 1024
local DEFAULT_DRAIN_TOTAL_S = 0.100
local DEFAULT_DRAIN_QUIET_S = 0.020
local DEFAULT_DRAIN_READ_S = 0.010
local BAD_LINE_SNIP_BYTES = 80
local RESYNC_PREFIX_SCAN_MAX_BYTES = 4096

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

local function log_wire(enabled, event, fields)
	if enabled ~= true then return end
	local parts = { '[fabric-wire]', tostring(event) }
	for k, v in pairs(fields or {}) do
		if v ~= nil then
			parts[#parts + 1] = tostring(k)
			parts[#parts + 1] = tostring(v)
		end
	end
	print(table.concat(parts, ' '))
end

local function wire_fields(frame, line)
	local out = {
		type = type(frame) == 'table' and frame.type or type(frame),
		id = type(frame) == 'table' and (frame.xfer_id or frame.sid) or nil,
		offset = type(frame) == 'table' and frame.offset or nil,
		next = type(frame) == 'table' and frame.next or nil,
		size = type(frame) == 'table' and frame.size or nil,
		line_len = type(line) == 'string' and #line or nil,
		line_xxhash32 = type(line) == 'string' and xxhash32.digest_hex(line) or nil,
	}
	if type(frame) == 'table' and frame.type == 'xfer_chunk' and type(frame.data) == 'string' then
		out.raw_len = #frame.data
		out.encoded_len = #protocol.encode_chunk(frame.data)
		out.chunk_digest = frame.chunk_digest
	end
	return out
end

local function escape_bytes(s)
	if type(s) ~= 'string' then return nil end
	local out = {}
	for i = 1, #s do
		local b = s:byte(i)
		if b == 9 then
			out[#out + 1] = '\\t'
		elseif b == 10 then
			out[#out + 1] = '\\n'
		elseif b == 13 then
			out[#out + 1] = '\\r'
		elseif b == 92 then
			out[#out + 1] = '\\\\'
		elseif b >= 32 and b <= 126 then
			out[#out + 1] = string.char(b)
		else
			out[#out + 1] = string.format('\\x%02x', b)
		end
	end
	return table.concat(out)
end

local function bad_line_diag(line, err)
	if type(line) ~= 'string' then
		return err
	end
	local head = line:sub(1, BAD_LINE_SNIP_BYTES)
	local tail = line
	if #line > BAD_LINE_SNIP_BYTES then
		tail = line:sub(#line - BAD_LINE_SNIP_BYTES + 1)
	end
	return {
		err = tostring(err or 'decode_failed'),
		last_decode_error = tostring(err or 'decode_failed'),
		last_bad_line_len = #line,
		last_bad_line_xxhash32 = xxhash32.digest_hex(line),
		last_bad_line_head = escape_bytes(head),
		last_bad_line_tail = escape_bytes(tail),
	}
end

local function blank_line(line)
	return type(line) == 'string' and line:match('^%s*$') ~= nil
end

local function non_printable_prefix(s)
	if type(s) ~= 'string' or s == '' then
		return false
	end
	for i = 1, #s do
		local b = s:byte(i)
		if b >= 32 and b <= 126 then
			return false
		end
	end
	return true
end

local function resync_diag(line, prefix_len, frame)
	return {
		line_resync = true,
		last_line_resync_prefix_len = prefix_len,
		last_line_resync_line_len = #line,
		last_line_resync_xxhash32 = xxhash32.digest_hex(line),
		last_line_resync_type = type(frame) == 'table' and frame.type or nil,
		last_line_resync_peer_sid = type(frame) == 'table' and frame.sid or nil,
		last_line_resync_xfer_id = type(frame) == 'table' and frame.xfer_id or nil,
	}
end

local function decode_line_with_resync(line)
	local frame, err = protocol.decode_line(line)
	if frame ~= nil then return frame, nil, nil end

	local scan = #line
	if scan > RESYNC_PREFIX_SCAN_MAX_BYTES then
		scan = RESYNC_PREFIX_SCAN_MAX_BYTES
	end
	local start = line:find('{', 1, true)
	if start ~= nil and start > 1 then
		if start > scan then
			return nil, err
		end
		local prefix_len = start - 1
		local prefix = line:sub(1, prefix_len)
		if non_printable_prefix(prefix) then
			local resynced, rerr = protocol.decode_line(line:sub(start))
			if resynced ~= nil then
				return resynced, nil, resync_diag(line, prefix_len, resynced)
			end
			return nil, rerr or err
		end
	end

	return nil, err
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

	if type(session.set_trace_io) == 'function' then
		session:set_trace_io(opts.trace_io == true)
	end

	return setmetatable({
		_session    = session,
		_mode       = mode,
		_terminator = terminator,
		_trace_io   = opts.trace_io == true,
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
	return fibers.run_scope_op(function ()
		while true do
			local line, err = fibers.perform(self:read_line_op())
			if line == nil then
				return nil, err
			end
			if blank_line(line) then
				log_wire(self._trace_io, 'blank_line_ignored', { line_len = #line })
			else
				local frame, derr, diag = decode_line_with_resync(line)
				if frame == nil then
					local diag = bad_line_diag(line, derr)
					log_wire(self._trace_io, 'decode_failed', diag)
					return nil, diag
				end
				if diag ~= nil then
					log_wire(self._trace_io, 'line_resynced', diag)
				end
				return frame, nil, diag
			end
		end
	end):wrap(function (status, report, frame, err, diag)
		if status ~= 'ok' then
			return nil, err or report or 'read_failed'
		end
		return frame, err, diag
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
			log_wire(self._trace_io, 'encode_failed', {
				type = type(frame) == 'table' and frame.type or type(frame),
				id = type(frame) == 'table' and (frame.xfer_id or frame.sid) or nil,
				err = enc_err,
			})
			return op.always(nil, enc_err)
		end

		log_wire(self._trace_io, 'write_line_begin', wire_fields(checked, line))
		return self:write_line_op(line):wrap(function (ok, err)
			local fields = wire_fields(checked, line)
			fields.err = err
			if ok == true then
				log_wire(self._trace_io, 'write_line_done', fields)
			else
				log_wire(self._trace_io, 'write_line_failed', fields)
			end
			return ok, err
		end)
	end)
end

function Transport:flush_op()
	return op.guard(function ()
		local session = self:_active_session_op()
		if session == nil then
			return op.always(true, nil)
		end

		if type(session.flush_op) ~= 'function' then
			return op.always(true, nil)
		end

		log_wire(self._trace_io, 'flush_begin', {})
		return session:flush_op():wrap(function (ok, err)
			if ok == true then
				log_wire(self._trace_io, 'flush_done', {})
			else
				log_wire(self._trace_io, 'flush_failed', { err = err or 'flush_failed' })
			end
			return normalise_bool(ok, err, 'flush_failed')
		end)
	end)
end

local function drain_limits(opts)
	opts = opts or {}
	local max_bytes = tonumber(opts.max_bytes) or DEFAULT_DRAIN_MAX_BYTES
	local total_s = tonumber(opts.total_s) or DEFAULT_DRAIN_TOTAL_S
	local quiet_s = tonumber(opts.quiet_s) or DEFAULT_DRAIN_QUIET_S
	local read_s = tonumber(opts.read_s) or DEFAULT_DRAIN_READ_S
	local chunk_size = tonumber(opts.chunk_size) or 4096

	if max_bytes < 0 then max_bytes = 0 end
	if total_s < 0 then total_s = 0 end
	if quiet_s < 0 then quiet_s = 0 end
	if read_s <= 0 then read_s = DEFAULT_DRAIN_READ_S end
	if chunk_size <= 0 then chunk_size = 4096 end

	return max_bytes, total_s, quiet_s, read_s, chunk_size
end

function Transport:drain_input_op(opts)
	return op.guard(function ()
		local session, closed = self:_active_session_op()
		if session == nil then
			return closed
		end
		if type(session.read_some_op) ~= 'function' then
			return op.always({
				bytes = 0,
				reads = 0,
				reason = 'unsupported',
			}, 'drain_unsupported')
		end

		return fibers.run_scope_op(function ()
			local max_bytes, total_s, quiet_s, read_s, chunk_size = drain_limits(opts)
			local deadline = fibers.now() + total_s
			local quiet_until = fibers.now() + quiet_s
			local bytes = 0
			local reads = 0
			local reason = 'quiet'

			while bytes < max_bytes do
				local now = fibers.now()
				local remaining_total = deadline - now
				local remaining_quiet = quiet_until - now
				if remaining_total <= 0 then
					reason = 'deadline'
					break
				end
				if remaining_quiet <= 0 then
					reason = 'quiet'
					break
				end

				local want = max_bytes - bytes
				if want > chunk_size then want = chunk_size end
				local timeout_s = math.min(read_s, remaining_total, remaining_quiet)
				local which, data, err = fibers.perform(fibers.named_choice {
					read = session:read_some_op(want),
					timeout = sleep.sleep_op(timeout_s),
				})

				if which ~= 'timeout' then
					if data == nil then
						reason = err or 'read_closed'
						break
					elseif data == '' then
						reason = 'empty_read'
						break
					else
						local n = #data
						bytes = bytes + n
						reads = reads + 1
						quiet_until = fibers.now() + quiet_s
						if bytes >= max_bytes then
							reason = 'max_bytes'
							break
						end
					end
				end
			end

			return {
				bytes = bytes,
				reads = reads,
				reason = reason,
			}, nil
		end):wrap(function (status, report, result, err)
			if status ~= 'ok' then
				return nil, err or report or 'drain_failed'
			end
			return result, err
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
			error(
				'fabric.hal_transport.open_transport_op: transport.' .. field .. ' must be a non-empty string',
				(level or 1) + 1
			)
		end
	end

	return cfg
end

local function append_field(parts, k, v)
	if v == nil then return end
	parts[#parts + 1] = tostring(k)
	parts[#parts + 1] = tostring(v)
end

local function log_transport(event, cfg, fields)
	if type(cfg) ~= 'table' or cfg.trace_io ~= true then return end
	fields = fields or {}
	local parts = { '[fabric-transport]', tostring(event) }
	if type(cfg) == 'table' then
		append_field(parts, 'source', cfg.source)
		append_field(parts, 'class', cfg.class)
		append_field(parts, 'id', cfg.id)
		append_field(parts, 'dependency', cfg.dependency_key)
	end
	append_field(parts, 'mode', fields.mode)
	append_field(parts, 'status', fields.status)
	append_field(parts, 'err', fields.err)
	append_field(parts, 'detail', fields.detail)
	print(table.concat(parts, ' '))
end

local function transport_open_error(cfg, err, detail)
	local e = {
		err = err or 'transport_open_failed',
		detail = detail or err,
		reason = detail or err or 'transport_open_failed',
	}
	if type(cfg) == 'table' then
		e.dependency_key = cfg.dependency_key
		e.source = cfg.source
		e.class = cfg.class
		e.id = cfg.id
	end
	local failure = dep_failure.from_no_route(e.dependency_key, e, {
		source = e.source,
		class = e.class,
		id = e.id,
	})
	return failure or e
end
local function reason_text(reason, fallback)
	if type(reason) == 'table' then
		return reason.err or reason.detail or reason.reason or fallback or 'transport_open_failed'
	end
	return reason or fallback or 'transport_open_failed'
end

local function unwrap_open_transport_reply(transport_cfg, reply, err)
	-- Backwards-compatible public helper: old callers passed (reply, err).
	-- New internal callers pass (transport_cfg, reply, err) so structured failures
	-- can carry dependency_key/source/class/id.
	if type(transport_cfg) == 'table'
		and reply ~= nil
		and (transport_cfg.ok ~= nil or transport_cfg.reason ~= nil or transport_cfg.err ~= nil)
		and transport_cfg.source == nil
		and transport_cfg.class == nil
		and transport_cfg.dependency_key == nil
	then
		err = reply
		reply = transport_cfg
		transport_cfg = nil
	elseif transport_cfg == nil and reply ~= nil and err == nil then
		-- Old nil-reply call shape: unwrap_open_transport_reply(nil, err).
		err = reply
		reply = nil
	end

	if reply == nil then
		return nil, transport_open_error(transport_cfg, err or 'transport_open_failed', err)
	end

	if type(reply) ~= 'table' then
		return nil, transport_open_error(transport_cfg, 'transport_open_reply_must_be_table', reply)
	end

	if reply.ok ~= true then
		local reason = reply.reason or reply.err or err or 'transport_open_failed'
		return nil, transport_open_error(transport_cfg, reason_text(reason), reason)
	end

	if type(reply.reason) ~= 'table' then
		return nil, transport_open_error(transport_cfg, 'transport_open_reply_reason_must_be_table', reply.reason)
	end

	local session = reply.reason.session
	if session == nil then
		return nil, transport_open_error(transport_cfg, 'transport_open_reply_missing_session')
	end

	return session, nil
end

local function normalise_open_opts(transport_cfg)
	local opts = transport_cfg.open_opts
	if transport_cfg.class == 'uart' then
		local checked, err = cap_sdk.args.new.UARTOpenOpts(opts)
		if not checked then
			return nil, err or 'invalid uart open opts'
		end
		return checked, nil
	end
	return opts, nil
end

function M.open_transport_op(conn, transport_cfg, transport_session)
	transport_cfg = require_transport_cfg(transport_cfg, 2)

	return op.guard(function ()
		if transport_session ~= nil then
			local transport, terr = M.wrap_transport(transport_session, transport_cfg)
			if not transport then
				log_transport('wrap_failed', transport_cfg, { err = terr or 'transport_wrap_failed' })
				return op.always(nil, terr or 'transport_wrap_failed')
			end
			log_transport('wrap_ok', transport_cfg, { mode = transport._mode })
			return op.always(transport, nil)
		end

		if conn == nil then
			log_transport('open_failed', transport_cfg, { err = 'transport_open_requires_bus_connection' })
			return op.always(nil, 'transport_open_requires_bus_connection')
		end

		local cap = cap_sdk.new_raw_host_cap_ref(
			conn,
			transport_cfg.source,
			transport_cfg.class,
			transport_cfg.id
		)
		local open_opts, oerr = normalise_open_opts(transport_cfg)
		if open_opts == nil and oerr ~= nil then
			log_transport('open_failed', transport_cfg, { err = oerr })
			return op.always(nil, oerr)
		end

		log_transport('open_start', transport_cfg)
		return cap:call_control_op(
			transport_cfg.open_verb or 'open',
			open_opts
		):wrap(function (reply, err)
			local session, uerr = unwrap_open_transport_reply(transport_cfg, reply, err)
			if not session then
				log_transport('open_failed', transport_cfg, {
					err = reason_text(uerr),
					detail = reason_text(err),
				})
				return nil, uerr
			end

			local transport, terr = M.wrap_transport(session, transport_cfg)
			if not transport then
				log_transport('wrap_failed', transport_cfg, { err = terr or 'transport_wrap_failed' })
				return nil, terr or 'transport_wrap_failed'
			end

			log_transport('open_ok', transport_cfg, { mode = transport._mode })
			return transport, nil
		end)
	end)
end

local function wait_for_transport_cap(conn, transport_cfg)
	local listener = cap_sdk.new_raw_host_cap_listener(
		conn,
		transport_cfg.source,
		transport_cfg.class,
		transport_cfg.id
	)

	local timeout_s = transport_cfg.cap_wait_timeout_s or DEFAULT_CAP_WAIT_TIMEOUT_S
	local which, cap, err = fibers.perform(op.named_choice {
		cap = listener:wait_for_cap_op(),
		timeout = sleep.sleep_op(timeout_s),
	})
	listener:close()

	if which == 'cap' then
		if cap == nil then
			return nil, err or 'transport_capability_unavailable'
		end
		return cap, nil
	end

	return nil, ('transport_capability_timeout source=%s class=%s id=%s timeout_s=%s'):format(
		tostring(transport_cfg.source),
		tostring(transport_cfg.class),
		tostring(transport_cfg.id),
		tostring(timeout_s)
	)
end

function M.open_transport(conn, transport_cfg, transport_session)
	transport_cfg = require_transport_cfg(transport_cfg, 2)

	if transport_session ~= nil then
		return fibers.perform(M.open_transport_op(conn, transport_cfg, transport_session))
	end

	if conn == nil then
		log_transport('open_failed', transport_cfg, { err = 'transport_open_requires_bus_connection' })
		return nil, 'transport_open_requires_bus_connection'
	end

	log_transport('open_start', transport_cfg)
	local cap, cap_err = wait_for_transport_cap(conn, transport_cfg)
	if cap == nil then
		log_transport('cap_wait_failed', transport_cfg, { err = cap_err })
		return nil, cap_err
	end

	local open_opts, oerr = normalise_open_opts(transport_cfg)
	if open_opts == nil and oerr ~= nil then
		log_transport('open_failed', transport_cfg, { err = oerr })
		return nil, oerr
	end

	local reply, err = fibers.perform(cap:call_control_op(
		transport_cfg.open_verb or 'open',
		open_opts
	))
	local session, uerr = unwrap_open_transport_reply(transport_cfg, reply, err)
	if not session then
		log_transport('open_failed', transport_cfg, {
			err = reason_text(uerr),
			detail = reason_text(err),
		})
		return nil, uerr
	end

	local transport, terr = M.wrap_transport(session, transport_cfg)
	if not transport then
		log_transport('wrap_failed', transport_cfg, { err = terr or 'transport_wrap_failed' })
		return nil, terr or 'transport_wrap_failed'
	end
	log_transport('open_ok', transport_cfg, { mode = transport._mode })
	return transport, nil
end

M.unwrap_open_transport_reply = unwrap_open_transport_reply

return M
