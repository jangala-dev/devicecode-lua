-- services/fabric/transfer.lua
--
-- Generic blob transfer manager for one fabric session.
--
-- Current policy:
--   * stop-and-wait
--   * one active outgoing transfer
--   * one active incoming transfer
--   * Base64url payload encoding
--
-- The sender is generic. The receiver uses an optional sink_factory(meta).
-- If no sink_factory is configured, incoming transfers are rejected.

local fibers   = require 'fibers'
local mailbox  = require 'fibers.mailbox'
local sleep    = require 'fibers.sleep'
local safe     = require 'coxpcall'

local b64url   = require 'services.fabric.b64url'
local checksum = require 'services.fabric.checksum'
local protocol = require 'services.fabric.protocol'

local perform      = fibers.perform
local named_choice = fibers.named_choice

local M = {}
local Transfer = {}
Transfer.__index = Transfer

local function inf() return 1 / 0 end
local RECENT_DONE_TTL_S = 5.0

local function t(...) return { ... } end

local function now(self)
	return self._svc and self._svc.now and self._svc:now() or fibers.now()
end

local function wall(self)
	return self._svc and self._svc.wall and self._svc:wall() or nil
end

local function update_state(self, st, status, fields)
	st.status = status or st.status
	st.updated_at = now(self)

	if fields then
		for k, v in pairs(fields) do
			st[k] = v
		end
	end

	local payload = {
		id          = st.id,
		dir         = st.dir,
		status      = st.status,
		link_id     = self._link_id,
		peer_id     = self._peer_id,
		kind        = st.kind,
		name        = st.name,
		format      = st.format,
		size        = st.size,
		sha256      = st.sha256,
		chunk_raw   = st.chunk_raw,
		chunks      = st.chunks,
		bytes_done  = st.bytes_done or 0,
		chunks_done = st.chunks_done or 0,
		started_at  = st.started_at,
		updated_at  = st.updated_at,
		at          = wall(self),
		err         = st.err,
		info        = st.info,
	}

	self._history[st.id] = payload

	self._conn:retain(t('state', 'fabric', 'transfer', st.id), payload)
	self._conn:retain(t('state', 'fabric', 'link', self._link_id, 'transfer'), payload)

	if self._svc and self._svc.obs_event then
		self._svc:obs_event('transfer_state', {
			id          = st.id,
			dir         = st.dir,
			status      = st.status,
			link_id     = self._link_id,
			peer_id     = self._peer_id,
			bytes_done  = payload.bytes_done,
			chunks_done = payload.chunks_done,
			size        = payload.size,
		})
	end
end

local function clear_link_pointer(self, st)
	self._conn:retain(t('state', 'fabric', 'link', self._link_id, 'transfer'), {
		id         = st.id,
		link_id    = self._link_id,
		peer_id    = self._peer_id,
		status     = st.status,
		updated_at = now(self),
		at         = wall(self),
	})
end

local function mailbox_recv_with_timeout(rx, timeout_s)
	local which, a = perform(named_choice {
		msg   = rx:recv_op(),
		timer = sleep.sleep_op(timeout_s):wrap(function() return true end),
	})

	if which == 'timer' then
		return nil, 'timeout'
	end

	if a == nil then
		return nil, 'closed'
	end

	return a, nil
end

local function ctrl_put(tx, msg)
	local ok, err = tx:send(msg)
	if ok == true then return true, nil end
	if ok == nil then return nil, 'closed' end
	return nil, tostring(err or 'full')
end

local function send_abort_best_effort(self, id, reason)
	safe.pcall(function()
		self._send_frame(protocol.xfer_abort(id, reason or 'aborted'))
	end)
end

local function purge_recent_in_done(self)
	local store = self._recent_in_done
	if type(store) ~= 'table' then
		return
	end

	local tnow = now(self)
	for id, rec in pairs(store) do
		if type(rec) ~= 'table' or type(rec.expires_at) ~= 'number' or rec.expires_at <= tnow then
			store[id] = nil
		end
	end
end

local function remember_recent_in_done(self, id, msg)
	if type(id) ~= 'string' or id == '' or type(msg) ~= 'table' then
		return
	end

	purge_recent_in_done(self)

	self._recent_in_done[id] = {
		msg        = msg,
		expires_at = now(self) + (self._recent_done_ttl_s or RECENT_DONE_TTL_S),
	}
end

local function resend_recent_in_done(self, id)
	purge_recent_in_done(self)

	local rec = self._recent_in_done and self._recent_in_done[id] or nil
	if not rec or type(rec.msg) ~= 'table' then
		return false, nil
	end

	local ok, err = self._send_frame(rec.msg)
	if ok ~= true then
		return nil, err
	end

	return true, nil
end

local function finalise_out(self, st, status, err, info)
	if st._finalised then
		return
	end
	st._finalised = true

	st.err = err and tostring(err) or nil
	st.info = info
	update_state(self, st, status)

	if self._out and self._out.id == st.id then
		self._out = nil
	end

	if st.ctrl_tx then st.ctrl_tx:close(status) end
	clear_link_pointer(self, st)
end

local function finalise_in(self, st, status, err, info)
	if st._finalised then
		return
	end
	st._finalised = true

	st.err = err and tostring(err) or nil
	st.info = info
	update_state(self, st, status)

	if self._in and self._in.id == st.id then
		self._in = nil
	end

	clear_link_pointer(self, st)
end

local function await_ctrl(st, timeout_s)
	return mailbox_recv_with_timeout(st.ctrl_rx, timeout_s)
end

local function sender_worker(self, st, source)
	local ack_timeout_s = self._ack_timeout_s
	local max_retries   = self._max_retries

	local function fail(reason)
		if st._finalised then
			return
		end
		send_abort_best_effort(self, st.id, reason)
		finalise_out(self, st, 'aborted', reason)
	end

	update_state(self, st, 'waiting_ready')

	local begin = protocol.xfer_begin(
		st.id,
		st.kind,
		st.name,
		st.format,
		'b64url',
		st.size,
		st.chunk_raw,
		st.chunks,
		st.sha256,
		st.meta
	)

	local ready = nil
	for _ = 1, max_retries do
		local ok, err = self._send_frame(begin)
		if ok ~= true then
			return fail(err or 'send_begin_failed')
		end

		local msg, werr = await_ctrl(st, ack_timeout_s)
		if not msg then
			if werr ~= 'timeout' then
				return fail(werr)
			end
		elseif msg.t == 'xfer_ready' then
			if msg.ok == true then
				ready = msg
				break
			end
			return fail(msg.err or 'remote_rejected')
		elseif msg.t == 'xfer_abort' then
			return fail(msg.reason or 'remote_abort')
		elseif msg.t == 'xfer_done' then
			if msg.ok == true then
				return fail('unexpected_done')
			end
			return fail(msg.err or 'remote_transfer_failed')
		end
	end

	if not ready then
		return fail('ready_timeout')
	end

	if (ready.next or 0) ~= 0 then
		return fail('resume_not_supported')
	end

	local reader = source:open()
	if type(reader) ~= 'table' or type(reader.read) ~= 'function' then
		return fail('source_open_failed')
	end

	local function close_reader()
		if reader and type(reader.close) == 'function' then
			pcall(function() reader:close() end)
		end
	end

	update_state(self, st, 'sending', { bytes_done = 0, chunks_done = 0 })

	local off = 0
	for seq = 0, st.chunks - 1 do
		local raw, rerr = reader:read(st.chunk_raw)
		if raw == nil then
			close_reader()
			return fail(rerr or 'unexpected_eof')
		end

		local frame = protocol.xfer_chunk(
			st.id,
			seq,
			off,
			#raw,
			checksum.crc32_hex(raw),
			b64url.encode(raw)
		)

		local acked = false
		for _ = 1, max_retries do
			local ok, err = self._send_frame(frame)
			if ok ~= true then
				close_reader()
				return fail(err or 'send_chunk_failed')
			end

			local msg, werr = await_ctrl(st, ack_timeout_s)
			if not msg then
				if werr ~= 'timeout' then
					close_reader()
					return fail(werr)
				end
			elseif msg.t == 'xfer_need' then
				if msg.next == seq + 1 then
					acked = true
					break
				elseif msg.next == seq then
					-- explicit resend request; loop again
				else
					close_reader()
					return fail('unexpected_need:' .. tostring(msg.next))
				end
			elseif msg.t == 'xfer_abort' then
				close_reader()
				return fail(msg.reason or 'remote_abort')
			elseif msg.t == 'xfer_done' then
				close_reader()
				if msg.ok == true then
					return fail('unexpected_done')
				end
				return fail(msg.err or 'remote_transfer_failed')
			end
		end

		if not acked then
			close_reader()
			return fail('chunk_ack_timeout')
		end

		off = off + #raw
		update_state(self, st, 'sending', {
			bytes_done  = off,
			chunks_done = seq + 1,
		})
	end

	close_reader()

	update_state(self, st, 'committing')

	local commit = protocol.xfer_commit(st.id, st.size, st.sha256)
	local done = nil

	for _ = 1, max_retries do
		local ok, err = self._send_frame(commit)
		if ok ~= true then
			return fail(err or 'send_commit_failed')
		end

		local msg, werr = await_ctrl(st, ack_timeout_s)
		if not msg then
			if werr ~= 'timeout' then
				return fail(werr)
			end
		elseif msg.t == 'xfer_done' then
			if msg.ok == true then
				done = msg
				break
			end
			return fail(msg.err or 'remote_commit_failed')
		elseif msg.t == 'xfer_abort' then
			return fail(msg.reason or 'remote_abort')
		end
	end

	if not done then
		return fail('commit_timeout')
	end

	finalise_out(self, st, 'done', nil, done.info)
end

local function incoming_begin(self, msg)
	if self._in ~= nil then
		self._send_frame(protocol.xfer_ready(msg.id, false, nil, 'busy'))
		return true, nil
	end

	if msg.enc ~= 'b64url' then
		self._send_frame(protocol.xfer_ready(msg.id, false, nil, 'unsupported_encoding'))
		return true, nil
	end

	if type(self._sink_factory) ~= 'function' then
		self._send_frame(protocol.xfer_ready(msg.id, false, nil, 'unsupported'))
		return true, nil
	end

	local meta = {
		id        = msg.id,
		kind      = msg.kind,
		name      = msg.name,
		format    = msg.format,
		enc       = msg.enc,
		size      = msg.size,
		chunk_raw = msg.chunk_raw,
		chunks    = msg.chunks,
		sha256    = msg.sha256,
		meta      = msg.meta,
	}

	local sink, err = self._sink_factory(meta)
	if not sink then
		self._send_frame(protocol.xfer_ready(msg.id, false, nil, tostring(err or 'sink_factory_failed')))
		return true, nil
	end

	if type(sink.begin) == 'function' then
		local ok, berr = sink:begin(meta)
		if ok ~= true then
			self._send_frame(protocol.xfer_ready(msg.id, false, nil, tostring(berr or 'sink_begin_failed')))
			return true, nil
		end
	end

	local st = {
		id            = msg.id,
		dir           = 'in',
		status        = 'receiving',
		started_at    = now(self),
		updated_at    = now(self),
		kind          = msg.kind,
		name          = msg.name,
		format        = msg.format,
		size          = msg.size,
		sha256        = msg.sha256,
		chunk_raw     = msg.chunk_raw,
		chunks        = msg.chunks,
		bytes_done    = 0,
		chunks_done   = 0,
		expected_next = 0,
		meta          = msg.meta,
		sink          = sink,
	}

	self._in = st
	update_state(self, st, 'receiving')
	self._send_frame(protocol.xfer_ready(msg.id, true, 0, nil))
	return true, nil
end

local function incoming_chunk(self, msg)
	local st = self._in
	if not st or st.id ~= msg.id then
		return false, 'no such incoming transfer'
	end

	if msg.seq ~= st.expected_next then
		self._send_frame(protocol.xfer_need(st.id, st.expected_next, 'unexpected_seq'))
		return true, nil
	end

	if msg.off ~= st.bytes_done then
		self._send_frame(protocol.xfer_need(st.id, st.expected_next, 'unexpected_offset'))
		return true, nil
	end

	local raw, derr = b64url.decode(msg.data)
	if raw == nil then
		self._send_frame(protocol.xfer_need(st.id, st.expected_next, 'decode_failed'))
		return true, nil
	end

	if #raw ~= msg.n then
		self._send_frame(protocol.xfer_need(st.id, st.expected_next, 'size_mismatch'))
		return true, nil
	end

	if checksum.crc32_hex(raw) ~= tostring(msg.crc32):lower() then
		self._send_frame(protocol.xfer_need(st.id, st.expected_next, 'bad_crc'))
		return true, nil
	end

	local ok, err = st.sink:write(msg.seq, msg.off, raw)
	if ok ~= true then
		if type(st.sink.abort) == 'function' then
			safe.pcall(function() st.sink:abort(err or 'write_failed') end)
		end
		self._send_frame(protocol.xfer_done(st.id, false, nil, tostring(err or 'write_failed')))
		finalise_in(self, st, 'aborted', err or 'write_failed')
		return true, nil
	end

	st.expected_next = st.expected_next + 1
	st.bytes_done    = st.bytes_done + #raw
	st.chunks_done   = st.chunks_done + 1

	update_state(self, st, 'receiving')
	self._send_frame(protocol.xfer_need(st.id, st.expected_next, nil))
	return true, nil
end

local function finish_in_with_done(self, st, ok, info, err, status)
	local done = protocol.xfer_done(st.id, ok, info, err)
	remember_recent_in_done(self, st.id, done)
	self._send_frame(done)
	finalise_in(self, st, status, err, info)
	return true, nil
end

local function incoming_commit(self, msg)
	local st = self._in
	if not st or st.id ~= msg.id then
		local resent, rerr = resend_recent_in_done(self, msg.id)
		if resent == true then
			return true, nil
		end
		if resent == nil then
			return nil, rerr
		end
		return false, 'no such incoming transfer'
	end

	if st.bytes_done ~= msg.size then
		if type(st.sink.abort) == 'function' then
			safe.pcall(function() st.sink:abort('size_mismatch') end)
		end
		return finish_in_with_done(self, st, false, nil, 'size_mismatch', 'aborted')
	end

	if type(st.sink.sha256hex) == 'function' then
		local got = st.sink:sha256hex()
		if type(got) ~= 'string' or got:lower() ~= tostring(msg.sha256):lower() then
			if type(st.sink.abort) == 'function' then
				safe.pcall(function() st.sink:abort('sha256_mismatch') end)
			end
			return finish_in_with_done(self, st, false, nil, 'sha256_mismatch', 'aborted')
		end
	end

	local info, err = st.sink:commit({
		id     = st.id,
		kind   = st.kind,
		name   = st.name,
		format = st.format,
		size   = msg.size,
		sha256 = msg.sha256,
		meta   = st.meta,
	})

	if info == nil and err ~= nil then
		return finish_in_with_done(self, st, false, nil, tostring(err), 'aborted')
	end

	return finish_in_with_done(self, st, true, info, nil, 'done')
end

local function incoming_abort(self, msg)
	local st = self._in
	if not st or st.id ~= msg.id then
		return false, 'no such incoming transfer'
	end

	if type(st.sink.abort) == 'function' then
		safe.pcall(function() st.sink:abort(msg.reason or 'remote_abort') end)
	end

	finalise_in(self, st, 'aborted', msg.reason or 'remote_abort')
	return true, nil
end

function M.new(opts)
	opts = opts or {}

	return setmetatable({
		_svc               = assert(opts.svc, 'transfer.new: svc is required'),
		_conn              = assert(opts.conn, 'transfer.new: conn is required'),
		_link_id           = assert(opts.link_id, 'transfer.new: link_id is required'),
		_peer_id           = opts.peer_id,
		_send_frame        = assert(opts.send_frame, 'transfer.new: send_frame is required'),
		_sink_factory      = opts.sink_factory,
		_chunk_raw         = (type(opts.chunk_raw) == 'number' and opts.chunk_raw > 0) and math.floor(opts.chunk_raw) or 768,
		_ack_timeout_s     = (type(opts.ack_timeout_s) == 'number' and opts.ack_timeout_s > 0) and opts.ack_timeout_s or 2.0,
		_max_retries       = (type(opts.max_retries) == 'number' and opts.max_retries > 0) and math.floor(opts.max_retries) or 5,
		_recent_done_ttl_s = (type(opts.recent_done_ttl_s) == 'number' and opts.recent_done_ttl_s > 0)
			and opts.recent_done_ttl_s
			or RECENT_DONE_TTL_S,
		_out              = nil,
		_in               = nil,
		_history          = {},
		_recent_in_done   = {},
	}, Transfer)
end

function Transfer:is_transfer_message(msg)
	local tt = type(msg) == 'table' and msg.t or nil
	return tt == 'xfer_begin'
		or tt == 'xfer_ready'
		or tt == 'xfer_chunk'
		or tt == 'xfer_need'
		or tt == 'xfer_commit'
		or tt == 'xfer_done'
		or tt == 'xfer_abort'
end

function Transfer:start_send(source, meta)
	meta = meta or {}

	if self._out ~= nil then
		return nil, 'outgoing transfer already active'
	end

	if type(source) ~= 'table' or type(source.open) ~= 'function' or type(source.size) ~= 'function' or type(source.sha256hex) ~= 'function' then
		return nil, 'source is not a valid blob source'
	end

	local size = source:size()
	if type(size) ~= 'number' or size < 0 then
		return nil, 'source:size() must return a non-negative number'
	end
	size = math.floor(size)

	local sha256 = source:sha256hex()
	if type(sha256) ~= 'string' or sha256 == '' then
		return nil, 'source:sha256hex() must return a non-empty string'
	end

	local name = meta.name or (type(source.name) == 'function' and source:name()) or 'blob'
	local kind = meta.kind or 'blob'
	local format = meta.format or ((type(source.format) == 'function' and source:format()) or 'bin')
	local chunk_raw = (type(meta.chunk_raw) == 'number' and meta.chunk_raw > 0)
		and math.floor(meta.chunk_raw)
		or self._chunk_raw

	local chunks = (size == 0) and 0 or math.floor((size + chunk_raw - 1) / chunk_raw)

	local ctrl_tx, ctrl_rx = mailbox.new(16, { full = 'reject_newest' })

	local st = {
		id          = protocol.next_id(),
		dir         = 'out',
		status      = 'starting',
		started_at  = now(self),
		updated_at  = now(self),
		kind        = tostring(kind),
		name        = tostring(name),
		format      = tostring(format),
		size        = size,
		sha256      = sha256,
		chunk_raw   = chunk_raw,
		chunks      = chunks,
		bytes_done  = 0,
		chunks_done = 0,
		meta        = meta.meta,
		ctrl_tx     = ctrl_tx,
		ctrl_rx     = ctrl_rx,
	}

	self._out = st
	update_state(self, st, 'starting')

	fibers.spawn(function()
		return sender_worker(self, st, source)
	end)

	return st.id, nil
end

function Transfer:status(id)
	if type(id) ~= 'string' or id == '' then
		return nil, 'transfer id must be a non-empty string'
	end

	if self._out and self._out.id == id then
		return self._history[id], nil
	end
	if self._in and self._in.id == id then
		return self._history[id], nil
	end
	if self._history[id] then
		return self._history[id], nil
	end
	return nil, 'unknown transfer'
end

function Transfer:abort(id, reason)
	reason = reason or 'aborted'

	if self._out and self._out.id == id then
		send_abort_best_effort(self, id, reason)
		finalise_out(self, self._out, 'aborted', reason)
		return true, nil
	end

	if self._in and self._in.id == id then
		if type(self._in.sink.abort) == 'function' then
			safe.pcall(function() self._in.sink:abort(reason) end)
		end
		send_abort_best_effort(self, id, reason)
		finalise_in(self, self._in, 'aborted', reason)
		return true, nil
	end

	return nil, 'unknown transfer'
end

function Transfer:abort_all(reason)
	if self._out then
		self:abort(self._out.id, reason or 'aborted')
	end
	if self._in then
		self:abort(self._in.id, reason or 'aborted')
	end
	return true
end

function Transfer:handle_incoming(msg)
	if type(msg) ~= 'table' then
		return nil, 'message must be a table'
	end

	purge_recent_in_done(self)

	local tt = msg.t

	-- Sender control messages.
	if (tt == 'xfer_ready' or tt == 'xfer_need' or tt == 'xfer_done' or tt == 'xfer_abort')
		and self._out and self._out.id == msg.id then
		return ctrl_put(self._out.ctrl_tx, msg)
	end

	-- Receiver state machine.
	if tt == 'xfer_begin' then
		return incoming_begin(self, msg)
	elseif tt == 'xfer_chunk' then
		return incoming_chunk(self, msg)
	elseif tt == 'xfer_commit' then
		return incoming_commit(self, msg)
	elseif tt == 'xfer_abort' then
		return incoming_abort(self, msg)
	end

	return nil, 'not a transfer message'
end

M.Transfer = Transfer

return M
