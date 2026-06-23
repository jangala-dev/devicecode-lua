-- services/fabric/transfer_sender.lua
--
-- Send-side Fabric transfer attempt worker.

local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'

local protocol = require 'services.fabric.protocol'

local M = {}

local DEFAULT_TIMEOUT = 1.0
local DEFAULT_CHUNK_SIZE = protocol.DEFAULT_CHUNK_SIZE or 2048

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

local function encoded_frame_len(frame)
	local line = protocol.encode_line(frame)
	if type(line) == 'string' then return #line end
	return nil
end

local function elapsed_ms(start)
	if start == nil then return nil end
	local dt = (fibers.now() - start) * 1000
	if dt < 0 then dt = 0 end
	return math.floor(dt + 0.5)
end

local function observe(caps, ev)
	if type(caps) ~= 'table' or type(caps.report_progress_now) ~= 'function' then
		return true, nil
	end
	ev.at = ev.at or fibers.now()
	return caps.report_progress_now(ev)
end

local function send(caps, lane, frame, label)
	local fn = lane == 'bulk' and caps.send_bulk_frame_now or caps.send_control_frame_now
	if type(fn) ~= 'function' then
		error('transfer_sender: missing session-bound sender for ' .. tostring(lane), 0)
	end

	local ok, err = fn(frame, label)
	if ok ~= true then error((label or 'transfer_send_failed') .. ': ' .. tostring(err), 0) end
	return true
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
	local started = fibers.now()
	local chunk, err = fibers.perform(source:read_chunk_op(n))
	if err ~= nil then return nil, err, elapsed_ms(started) end
	return chunk, nil, elapsed_ms(started)
end

local function send_commit(caps, xfer_id, size, alg, digest, timeout_s)
	local frame = construct('xfer_commit', protocol.xfer_commit, xfer_id, size, alg, digest)
	send(caps, 'control', frame, 'transfer_commit_send_failed')
	return 'committing', fibers.now() + timeout_s
end

local function make_next_chunk(caps, source, xfer_id, offset, size, chunk_size)
	local want = math.min(chunk_size, size - offset)
	local chunk, err, source_read_ms = read_chunk(source, want)

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

	return {
		offset = offset,
		next = offset + #chunk,
		len = #chunk,
		digest = chunk_digest,
		frame_len = encoded_frame_len(frame),
		source_read_ms = source_read_ms,
		frame = frame,
	}
end

local function send_chunk(caps, pending)
	local started = fibers.now()
	send(caps, 'bulk', pending.frame, 'transfer_chunk_send_failed')
	return true, elapsed_ms(started)
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
	local chunks_sent = 0
	local retransmits = 0
	local max_frame_queue_ms = 0
	local max_need_to_chunk_ms = 0
	local max_source_read_ms = 0
	local max_send_ms = 0

	local function note_max(name, value)
		if type(value) ~= 'number' then return end
		if name == 'frame_queue' and value > max_frame_queue_ms then max_frame_queue_ms = value end
		if name == 'need_to_chunk' and value > max_need_to_chunk_ms then max_need_to_chunk_ms = value end
		if name == 'source_read' and value > max_source_read_ms then max_source_read_ms = value end
		if name == 'send' and value > max_send_ms then max_send_ms = value end
	end

	local function report(ev)
		ev = ev or {}
		ev.xfer_id = xfer_id
		ev.target = target
		ev.size = size
		ev.digest_alg = alg
		ev.digest = digest
		ev.sent_bytes = ev.sent_bytes or 0
		ev.chunks_sent = chunks_sent
		ev.retransmits = retransmits or 0
		ev.max_frame_queue_ms = max_frame_queue_ms
		ev.max_need_to_chunk_ms = max_need_to_chunk_ms
		ev.max_source_read_ms = max_source_read_ms
		ev.max_send_ms = max_send_ms
		return observe(caps, ev)
	end

	local begin = construct('xfer_begin', protocol.xfer_begin,
		xfer_id, target, size, alg, digest, req.meta)

	local begin_send_start = fibers.now()
	send(caps, 'control', begin, 'transfer_begin_send_failed')
	note_max('send', elapsed_ms(begin_send_start))
	report { event = 'xfer_begin_tx', phase = 'waiting_ready', last_tx_type = 'xfer_begin' }

	-- `sent` is the receiver-acknowledged offset. `pending` is the one
	-- outstanding chunk that may be resent if the receiver asks again for the
	-- same offset. This deliberately stays stop-and-wait; there is no seek,
	-- resume, or sliding window in v1.
	local sent = 0
	local pending = nil
	local state = 'waiting_ready'
	local deadline = fibers.now() + timeout_s

	while true do
		local which, item = fibers.perform(wait_frame_op(rx, deadline))
		if which == 'timeout' then
			report { event = 'timeout', phase = state, err = 'timeout', sent_bytes = sent, pending_offset = pending and pending.offset or nil, pending_next = pending and pending.next or nil }
			fail(caps, xfer_id, 'timeout', true)
		end
		if item == nil then error('transfer_sender_frame_feed_closed', 0) end

		local frame = item.frame or item
		local frame_queue_ms = nil
		if type(item) == 'table' and type(item.at) == 'number' then
			frame_queue_ms = elapsed_ms(item.at)
			note_max('frame_queue', frame_queue_ms)
		end

		if type(frame) ~= 'table' or frame.xfer_id ~= xfer_id then
			-- Manager normally filters these.

		elseif frame.type == 'xfer_abort' then
			report {
				event = 'xfer_abort_rx',
				phase = state,
				last_rx_type = 'xfer_abort',
				err = frame.err or 'remote_abort',
				frame_queue_ms = frame_queue_ms,
				sent_bytes = sent,
			}
			fail(caps, xfer_id, frame.err or 'remote_abort', false)

		elseif frame.type == 'xfer_ready' then
			if state == 'waiting_ready' then
				state = 'sending'
				deadline = fibers.now() + timeout_s
			end
			report {
				event = 'xfer_ready_rx',
				phase = state,
				last_rx_type = 'xfer_ready',
				frame_queue_ms = frame_queue_ms,
				sent_bytes = sent,
			}

		elseif frame.type == 'xfer_need' then
			if state ~= 'sending' then fail(caps, xfer_id, 'unexpected_need', true) end
			local need_at = fibers.now()
			report {
				event = 'xfer_need_rx',
				phase = state,
				last_rx_type = 'xfer_need',
				last_rx_next = frame.next,
				requested_next = frame.next,
				pending_offset = pending and pending.offset or nil,
				pending_next = pending and pending.next or nil,
				frame_queue_ms = frame_queue_ms,
				sent_bytes = sent,
			}

			if pending ~= nil then
				if frame.next == pending.offset then
					-- Receiver rejected or lost the last chunk before advancing.
					-- Resend the cached frame without reading from the source again.
					local _, send_ms = send_chunk(caps, pending)
					note_max('send', send_ms)
					local need_to_chunk_ms = elapsed_ms(need_at)
					note_max('need_to_chunk', need_to_chunk_ms)
					retransmits = retransmits + 1
					report {
						event = 'xfer_chunk_tx',
						phase = state,
						last_tx_type = 'xfer_chunk',
						last_tx_offset = pending.offset,
						last_tx_next = pending.next,
						chunk_len = pending.len,
						chunk_digest = pending.digest,
						chunk_frame_len = pending.frame_len,
						send_ms = send_ms,
						need_to_chunk_ms = need_to_chunk_ms,
						retransmit = true,
						sent_bytes = sent,
					}
					deadline = fibers.now() + timeout_s

				elseif frame.next == pending.next then
					sent = pending.next
					pending = nil
					if sent >= size then
						state, deadline = send_commit(caps, xfer_id, size, alg, digest, timeout_s)
						report {
							event = 'xfer_commit_tx',
							phase = state,
							last_tx_type = 'xfer_commit',
							sent_bytes = sent,
						}
					else
						pending = make_next_chunk(caps, source, xfer_id, sent, size, chunk_size)
						note_max('source_read', pending.source_read_ms)
						local _, send_ms = send_chunk(caps, pending)
						note_max('send', send_ms)
						chunks_sent = chunks_sent + 1
						local need_to_chunk_ms = elapsed_ms(need_at)
						note_max('need_to_chunk', need_to_chunk_ms)
						report {
							event = 'xfer_chunk_tx',
							phase = state,
							last_tx_type = 'xfer_chunk',
							last_tx_offset = pending.offset,
							last_tx_next = pending.next,
							chunk_len = pending.len,
							chunk_digest = pending.digest,
							chunk_frame_len = pending.frame_len,
							source_read_ms = pending.source_read_ms,
							send_ms = send_ms,
							need_to_chunk_ms = need_to_chunk_ms,
							sent_bytes = sent,
						}
						deadline = fibers.now() + timeout_s
					end

				else
					fail(caps, xfer_id, 'unexpected_offset', true)
				end

			else
				if frame.next ~= sent then fail(caps, xfer_id, 'unexpected_offset', true) end
				if sent >= size then
					state, deadline = send_commit(caps, xfer_id, size, alg, digest, timeout_s)
					report {
						event = 'xfer_commit_tx',
						phase = state,
						last_tx_type = 'xfer_commit',
						sent_bytes = sent,
					}
				else
					pending = make_next_chunk(caps, source, xfer_id, sent, size, chunk_size)
					note_max('source_read', pending.source_read_ms)
					local _, send_ms = send_chunk(caps, pending)
					note_max('send', send_ms)
					chunks_sent = chunks_sent + 1
					local need_to_chunk_ms = elapsed_ms(need_at)
					note_max('need_to_chunk', need_to_chunk_ms)
					report {
						event = 'xfer_chunk_tx',
						phase = state,
						last_tx_type = 'xfer_chunk',
						last_tx_offset = pending.offset,
						last_tx_next = pending.next,
						chunk_len = pending.len,
						chunk_digest = pending.digest,
						chunk_frame_len = pending.frame_len,
						source_read_ms = pending.source_read_ms,
						send_ms = send_ms,
						need_to_chunk_ms = need_to_chunk_ms,
						sent_bytes = sent,
					}
					deadline = fibers.now() + timeout_s
				end
			end

		elseif frame.type == 'xfer_done' and state == 'committing' then
			report {
				event = 'xfer_done_rx',
				phase = 'done',
				last_rx_type = 'xfer_done',
				frame_queue_ms = frame_queue_ms,
				sent_bytes = sent,
			}
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
				chunks_sent = chunks_sent,
				max_frame_queue_ms = max_frame_queue_ms,
				max_need_to_chunk_ms = max_need_to_chunk_ms,
				max_source_read_ms = max_source_read_ms,
				max_send_ms = max_send_ms,
			}
		end
	end
end

return M
