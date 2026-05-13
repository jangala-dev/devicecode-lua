-- services/fabric/transfer_sender.lua
--
-- Send-side Fabric transfer attempt worker.

local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'

local protocol = require 'services.fabric.protocol'

local M = {}

local DEFAULT_TIMEOUT = 1.0
local DEFAULT_CHUNK_SIZE = protocol.DEFAULT_CHUNK_SIZE or 2048
local DEFAULT_RESEND_RETRY_S = 0.25

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
	local xfer_id = req.xfer_id or req.request_id
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

local function send_now(caps, lane, frame, label)
	local fn = lane == 'bulk' and caps.send_bulk_frame_now or caps.send_control_frame_now
	if type(fn) ~= 'function' then
		error('transfer_sender: missing session-bound sender for ' .. tostring(lane), 0)
	end

	return fn(frame, label)
end

local function send(caps, lane, frame, label)
	local ok, err = send_now(caps, lane, frame, label)
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
	local chunk, err = fibers.perform(source:read_chunk_op(n))
	if err ~= nil then return nil, err end
	return chunk, nil
end

local function send_commit(caps, xfer_id, size, alg, digest, timeout_s)
	local frame = construct('xfer_commit', protocol.xfer_commit, xfer_id, size, alg, digest)
	send(caps, 'control', frame, 'transfer_commit_send_failed')
	return 'committing', fibers.now() + timeout_s
end

local function send_next_chunk(caps, source, xfer_id, sent, size, chunk_size)
	local want = math.min(chunk_size, size - sent)
	local chunk, err = read_chunk(source, want)

	if err ~= nil then fail(caps, xfer_id, err, true) end
	if type(chunk) ~= 'string' or #chunk == 0 then fail(caps, xfer_id, 'short_source', true) end
	if sent + #chunk > size then fail(caps, xfer_id, 'source_overrun', true) end

	local frame = construct(
		'xfer_chunk',
		protocol.xfer_chunk,
		xfer_id,
		sent,
		chunk,
		protocol.chunk_digest(chunk),
		protocol.chunk_offset_digest(xfer_id, sent, chunk)
	)

	send(caps, 'bulk', frame, 'transfer_chunk_send_failed')
	local next_sent = sent + #chunk
	return next_sent, {
		offset = sent,
		next = next_sent,
		frame = frame,
	}
end

local function resend_cached_chunk(caps, cache, requested)
	if type(cache) ~= 'table' or cache.offset ~= requested then
		return nil, 'unexpected_offset'
	end

	local ok, err = send_now(caps, 'bulk', cache.frame, 'transfer_chunk_resend_failed')
	if ok ~= true then return nil, err or 'transfer_chunk_resend_failed' end
	return cache.next, nil
end

local function is_queue_full(err)
	local s = tostring(err or '')
	return s == 'full' or s:match(': full$') ~= nil
end

local function mark_inflight(cache)
	if type(cache) ~= 'table' then return nil end
	return {
		offset = cache.offset,
		next = cache.next,
		sent_at = fibers.now(),
	}
end

local function resend_due(inflight, requested, resend_retry_s)
	if type(inflight) ~= 'table' or inflight.offset ~= requested then return true end
	return fibers.now() - (inflight.sent_at or 0) >= resend_retry_s
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
	local resend_retry_s = positive(
		req.resend_retry_s or caps.resend_retry_s,
		DEFAULT_RESEND_RETRY_S,
		'resend_retry_s'
	)
	local begin_retry_s = math.min(2.0, math.max(0.25, timeout_s / 5))

	local begin = construct('xfer_begin', protocol.xfer_begin,
		xfer_id, target, size, alg, digest, req.meta or req.metadata)

	send(caps, 'control', begin, 'transfer_begin_send_failed')

	local sent = 0
	local retry_cache = nil
	local inflight = nil
	local state = 'waiting_ready'
	local ready_deadline = fibers.now() + timeout_s
	local deadline = math.min(fibers.now() + begin_retry_s, ready_deadline)

	while true do
		local which, item = fibers.perform(wait_frame_op(rx, deadline))
		if which == 'timeout' then
			local now = fibers.now()
			if state == 'waiting_ready' and now < ready_deadline then
				send(caps, 'control', begin, 'transfer_begin_send_failed')
				deadline = math.min(now + begin_retry_s, ready_deadline)
			else
				fail(caps, xfer_id, 'timeout', true)
			end
		else
			if item == nil then error('transfer_sender_frame_feed_closed', 0) end

			local frame = item.frame or item

			if type(frame) == 'table' and frame.xfer_id == xfer_id then
				if frame.type == 'xfer_abort' then
					fail(caps, xfer_id, frame.err or 'remote_abort', false)

				elseif frame.type == 'xfer_ready' then
					if state == 'waiting_ready' then
						state = 'sending'
						deadline = fibers.now() + timeout_s
					end

				elseif frame.type == 'xfer_need' then
					if frame.next < sent then
						deadline = fibers.now() + timeout_s
						if resend_due(inflight, frame.next, resend_retry_s) then
							local resent, rerr = resend_cached_chunk(caps, retry_cache, frame.next)
							if not resent then
								if is_queue_full(rerr) then
									inflight = mark_inflight(retry_cache)
									state = 'sending'
								else
									fail(caps, xfer_id, rerr, true)
								end
							else
								sent = resent
								inflight = mark_inflight(retry_cache)
								state = 'sending'
							end
						end

					else
						if state ~= 'sending' then fail(caps, xfer_id, 'unexpected_need', true) end
						if frame.next ~= sent then fail(caps, xfer_id, 'unexpected_offset', true) end

						if sent >= size then
							inflight = nil
							state, deadline = send_commit(caps, xfer_id, size, alg, digest, timeout_s)
						else
							sent, retry_cache = send_next_chunk(caps, source, xfer_id, sent, size, chunk_size)
							inflight = mark_inflight(retry_cache)
							deadline = fibers.now() + timeout_s

							if sent == size then
								state, deadline = 'sending', fibers.now() + timeout_s
							end
						end
					end

				elseif frame.type == 'xfer_done' and state == 'committing' then
					return {
						request_id = req.request_id,
						target = target,
						xfer_id = xfer_id,
						digest_alg = alg,
						digest = digest,
						sent_bytes = sent,
						size = size,
					}
				end
			end
		end
	end
end

return M
