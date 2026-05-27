-- services/fabric/transfer_sender.lua
--
-- Send-side Fabric transfer attempt worker.

local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'

local protocol = require 'services.fabric.protocol'
local xxhash32 = require 'shared.hash.xxhash32'

local M = {}

local DEFAULT_TIMEOUT = 1.0
local DEFAULT_CHUNK_SIZE = protocol.DEFAULT_CHUNK_SIZE or 2048
local DEFAULT_REPORT_BYTES = 8192
local BACKPRESSURE_RETRY_S = 0.005
local RESEND_MIN_INTERVAL_S = 0.25

local REPORT_BYTES = DEFAULT_REPORT_BYTES

local function log_xfer(trace_io, event, fields)
	if trace_io ~= true then return end
	local parts = { '[fabric-xfer-tx]', tostring(event) }
	for k, v in pairs(fields or {}) do
		if v ~= nil then
			parts[#parts + 1] = tostring(k)
			parts[#parts + 1] = tostring(v)
		end
	end
	print(table.concat(parts, ' '))
end

local function encoded_chunk_len(frame)
	if type(frame) ~= 'table' or frame.type ~= 'xfer_chunk' or type(frame.data) ~= 'string' then
		return nil
	end
	local encoded = protocol.encode_chunk(frame.data)
	return #encoded
end

local function line_diag(frame)
	local line, err = protocol.encode_line(frame)
	if type(line) ~= 'string' then
		return nil, nil, err
	end
	return #line, xxhash32.digest_hex(line), nil
end

local function nonempty(v)
	return type(v) == 'string' and v ~= ''
end

local function nonneg_int(v)
	return type(v) == 'number'
		and v == v and v ~= math.huge and v ~= -math.huge
		and v >= 0 and v % 1 == 0
end

local function positive(v, fallback, name, integer)
	v = v or fallback
	if type(v) ~= 'number' or v <= 0 or v ~= v or v == math.huge or v == -math.huge then
		error('transfer_sender: ' .. name .. ' must be positive', 0)
	end
	if integer and v % 1 ~= 0 then
		error('transfer_sender: ' .. name .. ' must be an integer', 0)
	end
	return v
end

local function require_source(req)
	local source = req.source
	if type(source) ~= 'table' or type(source.read_chunk_op) ~= 'function' then
		error('transfer_sender: source with read_chunk_op required', 0)
	end
	return source
end

local function require_request(req)
	local xfer_id = req.xfer_id
	if not nonempty(xfer_id) then error('transfer_sender: xfer_id required', 0) end
	if not nonempty(req.target) then error('transfer_sender: target required', 0) end
	if not nonneg_int(req.size) then error('transfer_sender: size must be a non-negative integer', 0) end

	local alg = req.digest_alg or protocol.DIGEST_ALG
	if alg ~= protocol.DIGEST_ALG then
		error('transfer_sender: unsupported digest_alg: ' .. tostring(alg), 0)
	end
	if not nonempty(req.digest) or not protocol.digest_ok(req.digest) then
		error('transfer_sender: digest must be xxhash32 hex', 0)
	end

	return xfer_id, req.target, req.size, alg, req.digest
end

local function construct(label, fn, ...)
	local frame, err = fn(...)
	if not frame then error(label .. ': ' .. tostring(err), 0) end
	return frame
end

local function is_backpressure(err)
	local s = tostring(err or '')
	return s == 'full'
		or s == 'would_block'
		or s:match(': full$') ~= nil
		or s:match(': would_block$') ~= nil
end

local function fail_send(label, err)
	local prefix = label or 'transfer_send_failed'
	local s = tostring(err or 'unknown')
	if s == prefix or s:sub(1, #prefix + 2) == prefix .. ': ' then
		error(s, 0)
	end
	error(prefix .. ': ' .. s, 0)
end

local function send(caps, lane, frame, label, deadline)
	local fn = lane == 'bulk' and caps.send_bulk_frame_now or caps.send_control_frame_now
	if type(fn) ~= 'function' then
		error('transfer_sender: missing session-bound sender for ' .. tostring(lane), 0)
	end

	while true do
		local ok, err = fn(frame, label)
		if ok == true then return true end
		if not is_backpressure(err) then
			fail_send(label, err)
		end
		if deadline ~= nil and fibers.now() >= deadline then
			fail_send(label, err)
		end
		fibers.perform(sleep.sleep_op(BACKPRESSURE_RETRY_S))
	end
end

local function try_abort(caps, xfer_id, reason)
	if type(caps.send_control_frame_now) ~= 'function' then return true, nil end
	local frame, err = protocol.xfer_abort(xfer_id, tostring(reason or 'aborted'))
	if not frame then return nil, err end
	return caps.send_control_frame_now(frame, 'transfer_abort_send_failed')
end

local function fail(caps, xfer_id, reason, send_abort)
	local err = tostring(reason or 'transfer_failed')

	if send_abort ~= false then
		local ok, aerr = try_abort(caps, xfer_id, err)
		if ok ~= true then err = err .. '; abort_failed: ' .. tostring(aerr) end
	end

	error(err, 0)
end

local function wait_frame_op(rx, deadline)
	local dt = deadline - fibers.now()
	if dt < 0 then dt = 0 end

	return fibers.named_choice {
		frame   = rx:recv_op(),
		timeout = sleep.sleep_op(dt),
	}
end

local function read_chunk(source, n)
	local chunk, err = fibers.perform(source:read_chunk_op(n))
	if err ~= nil then return nil, err end
	return chunk, nil
end

local function send_commit(caps, xfer_id, size, alg, digest, timeout_s, deadline, trace_io)
	local frame = construct('xfer_commit', protocol.xfer_commit, xfer_id, size, alg, digest)
	log_xfer(trace_io, 'commit_tx', {
		id = xfer_id,
		size = size,
		digest = digest,
	})
	send(caps, 'control', frame, 'transfer_commit_send_failed', deadline)
	return 'committing', fibers.now() + timeout_s
end

local function make_next_chunk(caps, source, xfer_id, offset, size, chunk_size, trace_io)
	local want = math.min(chunk_size, size - offset)
	local read_start = fibers.now()
	local chunk, err = read_chunk(source, want)
	local read_ms = math.floor((fibers.now() - read_start) * 1000 + 0.5)

	if err ~= nil then fail(caps, xfer_id, err, true) end
	if type(chunk) ~= 'string' or #chunk == 0 then fail(caps, xfer_id, 'short_source', true) end
	if offset + #chunk > size then fail(caps, xfer_id, 'source_overrun', true) end
	local chunk_digest = protocol.chunk_digest(chunk)

	local frame = construct(
		'xfer_chunk',
		protocol.xfer_chunk,
		xfer_id,
		offset,
		chunk,
		chunk_digest
	)
	local encoded_len
	local line_len
	local line_hash
	local line_err
	if trace_io == true then
		encoded_len = encoded_chunk_len(frame)
		line_len, line_hash, line_err = line_diag(frame)
	end

	log_xfer(trace_io, 'chunk_make', {
		id = xfer_id,
		offset = offset,
		next = offset + #chunk,
		raw_len = #chunk,
		encoded_len = encoded_len,
		chunk_digest = chunk_digest,
		line_len = line_len,
		line_xxhash32 = line_hash,
		line_err = line_err,
		read_ms = read_ms,
	})

	return {
		offset = offset,
		next = offset + #chunk,
		frame = frame,
		raw_len = #chunk,
		encoded_len = encoded_len,
		chunk_digest = chunk_digest,
		line_len = line_len,
		line_xxhash32 = line_hash,
	}
end

local function send_chunk(caps, pending, deadline, trace_io)
	log_xfer(trace_io, 'chunk_send', {
		id = pending.frame.xfer_id,
		offset = pending.offset,
		next = pending.next,
		raw_len = pending.raw_len,
		encoded_len = pending.encoded_len,
		chunk_digest = pending.chunk_digest,
		line_len = pending.line_len,
		line_xxhash32 = pending.line_xxhash32,
	})
	send(caps, 'bulk', pending.frame, 'transfer_chunk_send_failed', deadline)
	pending.last_tx_at = fibers.now()
	return true
end

function M.run(scope, req, caps)
	if type(scope) ~= 'table' then error('transfer_sender.run: scope required', 2) end
	if type(req) ~= 'table' then error('transfer_sender.run: request table required', 2) end
	if type(caps) ~= 'table' then error('transfer_sender.run: caps table required', 2) end

	local rx = caps.frame_rx
	if type(rx) ~= 'table' or type(rx.recv_op) ~= 'function' then
		error('transfer_sender: frame_rx required', 0)
	end

	local source = require_source(req)
	local xfer_id, target, size, alg, digest = require_request(req)
	local timeout_s = positive(req.timeout_s or caps.timeout_s, DEFAULT_TIMEOUT, 'timeout_s')
	local chunk_size = positive(req.chunk_size or caps.chunk_size, DEFAULT_CHUNK_SIZE, 'chunk_size', true)
	local trace_io = req.trace_io == true or caps.trace_io == true

	log_xfer(trace_io, 'start', {
		id = xfer_id,
		target = target,
		size = size,
		digest_alg = alg,
		digest = digest,
		chunk_size = chunk_size,
		timeout_s = timeout_s,
	})

	local begin = construct('xfer_begin', protocol.xfer_begin,
		xfer_id, target, size, alg, digest, req.meta)

	log_xfer(trace_io, 'begin_tx', {
		id = xfer_id,
		target = target,
		size = size,
		digest = digest,
	})
	send(caps, 'control', begin, 'transfer_begin_send_failed', fibers.now() + timeout_s)

	-- `sent` is the receiver-acknowledged offset. `pending` is the one
	-- outstanding chunk that may be resent if the receiver asks again for the
	-- same offset. This deliberately stays stop-and-wait; there is no seek,
	-- resume, or sliding window in v1.
	local sent = 0
	local pending = nil
	local retransmits = 0
	local state = 'waiting_ready'
	local deadline = fibers.now() + timeout_s
	local next_report_at = chunk_size

	local function report_progress(status)
		if type(req.on_progress) ~= 'function' then return end
		local ok, err = req.on_progress({
			xfer_id = xfer_id,
			sent = sent,
			size = size,
			status = status or state,
		})
		if ok == false then error(err or 'transfer_progress_report_failed', 0) end
	end

	local function note_report_progress()
		if REPORT_BYTES <= 0 then return end
		if sent < size and sent < next_report_at then return end
		report_progress('sending')
		while next_report_at <= sent do
			next_report_at = next_report_at + REPORT_BYTES
		end
	end

	local function resend_pending(event, suppressed_event, requested_next)
		local last_tx_at = pending.last_tx_at or 0
		if fibers.now() - last_tx_at >= RESEND_MIN_INTERVAL_S then
			send_chunk(caps, pending, deadline, trace_io)
			retransmits = retransmits + 1
			log_xfer(trace_io, event or 'chunk_resend', {
				id = xfer_id,
				offset = pending.offset,
				next = pending.next,
				requested_next = requested_next,
				retransmits = retransmits,
			})
		else
			log_xfer(trace_io, suppressed_event or 'chunk_resend_suppressed', {
				id = xfer_id,
				offset = pending.offset,
				next = pending.next,
				requested_next = requested_next,
				age_ms = math.floor((fibers.now() - last_tx_at) * 1000 + 0.5),
			})
		end
	end

	while true do
		local which, item = fibers.perform(wait_frame_op(rx, deadline))
		if which == 'timeout' then
			log_xfer(trace_io, 'timeout', {
				id = xfer_id,
				state = state,
				sent = sent,
				pending_offset = pending and pending.offset,
				pending_next = pending and pending.next,
				retransmits = retransmits,
			})
			fail(caps, xfer_id, 'timeout', true)
		end
		if item == nil then
			local reason = type(rx.why) == 'function' and rx:why() or nil
			log_xfer(trace_io, 'frame_feed_closed', {
				id = xfer_id,
				state = state,
				sent = sent,
				reason = reason or 'closed',
			})
			error('transfer_sender_frame_feed_closed: ' .. tostring(reason or 'closed'), 0)
		end

		local frame = item.frame or item

		if type(frame) == 'table' and frame.xfer_id == xfer_id then
			if frame.type == 'xfer_abort' then
				log_xfer(trace_io, 'abort_rx', {
					id = xfer_id,
					err = frame.err or 'remote_abort',
					state = state,
					sent = sent,
				})
				fail(caps, xfer_id, frame.err or 'remote_abort', false)

			elseif frame.type == 'xfer_ready' then
				log_xfer(trace_io, 'ready_rx', {
					id = xfer_id,
					state = state,
					sent = sent,
				})
				if state == 'waiting_ready' then
					state = 'sending'
					deadline = fibers.now() + timeout_s
				end

				elseif frame.type == 'xfer_need' then
					log_xfer(trace_io, 'need_rx', {
						id = xfer_id,
						next = frame.next,
						state = state,
						sent = sent,
						pending_offset = pending and pending.offset,
						pending_next = pending and pending.next,
					})
					if state ~= 'sending' then fail(caps, xfer_id, 'unexpected_need', true) end

					if pending ~= nil then
						if frame.next == pending.offset then
							-- Receiver rejected or lost the last chunk before advancing.
							-- Resend the cached frame without reading from the source again,
							-- but coalesce duplicate needs while the previous copy is still
							-- likely queued or on a slow UART.
							resend_pending('chunk_resend', 'chunk_resend_suppressed', frame.next)
							deadline = fibers.now() + timeout_s

						elseif frame.next == pending.next then
							sent = pending.next
							log_xfer(trace_io, 'chunk_ack', {
								id = xfer_id,
								next = sent,
								raw_len = pending.raw_len,
								chunk_digest = pending.chunk_digest,
							})
							note_report_progress()
							pending = nil
							if sent >= size then
								state, deadline = send_commit(caps, xfer_id, size, alg, digest, timeout_s, deadline, trace_io)
							else
								pending = make_next_chunk(caps, source, xfer_id, sent, size, chunk_size, trace_io)
								send_chunk(caps, pending, deadline, trace_io)
								deadline = fibers.now() + timeout_s
							end

						elseif type(frame.next) == 'number' and frame.next < pending.offset then
							-- UART links can deliver an older xfer_need after the sender has
							-- already advanced. That is stale control traffic, not a transfer
							-- contract violation.
							log_xfer(trace_io, 'stale_need_ignored', {
								id = xfer_id,
								next = frame.next,
								pending_offset = pending.offset,
								pending_next = pending.next,
							})
							deadline = fibers.now() + timeout_s

						else
							log_xfer(trace_io, 'future_need', {
								id = xfer_id,
								next = frame.next,
								pending_offset = pending.offset,
								pending_next = pending.next,
							})
							resend_pending('future_need_resend', 'future_need_resend_suppressed', frame.next)
						end

					else
						if type(frame.next) == 'number' and frame.next < sent then
							-- Stale request for already-acknowledged data; ignore it.
							log_xfer(trace_io, 'stale_need_ignored', {
								id = xfer_id,
								next = frame.next,
								sent = sent,
							})
							deadline = fibers.now() + timeout_s
						else
							if frame.next ~= sent then
								log_xfer(trace_io, 'future_need', {
									id = xfer_id,
									next = frame.next,
									sent = sent,
								})
							end
							if sent >= size then
								state, deadline = send_commit(caps, xfer_id, size, alg, digest, timeout_s, deadline, trace_io)
							else
								pending = make_next_chunk(caps, source, xfer_id, sent, size, chunk_size, trace_io)
								send_chunk(caps, pending, deadline, trace_io)
								if frame.next == sent then
									deadline = fibers.now() + timeout_s
								end
							end
						end
					end

				elseif frame.type == 'xfer_done' and state == 'committing' then
					log_xfer(trace_io, 'done_rx', {
						id = xfer_id,
						sent = sent,
						size = size,
						retransmits = retransmits,
					})
					return {
						request_id = req.request_id,
						job_id = type(req.meta) == 'table' and req.meta.job_id or nil,
						component = type(req.meta) == 'table' and req.meta.component or nil,
						image_id = type(req.meta) == 'table' and req.meta.image_id or nil,
						target = target,
						xfer_id = xfer_id,
						digest_alg = alg,
						digest = digest,
						sent_bytes = sent,
						size = size,
						retransmits = retransmits,
					}
				end
		end
	end
end

return M
