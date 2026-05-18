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
	local chunk, err = fibers.perform(source:read_chunk_op(n))
	if err ~= nil then return nil, err end
	return chunk, nil
end

local function send_commit(caps, xfer_id, size, alg, digest, timeout_s)
	local frame = construct('xfer_commit', protocol.xfer_commit, xfer_id, size, alg, digest)
	send(caps, 'control', frame, 'transfer_commit_send_failed')
	return 'committing', fibers.now() + timeout_s
end

local function send_chunk(caps, xfer_id, offset, chunk)
	local frame = construct(
		'xfer_chunk',
		protocol.xfer_chunk,
		xfer_id,
		offset,
		chunk,
		protocol.chunk_digest(chunk)
	)

	send(caps, 'bulk', frame, 'transfer_chunk_send_failed')
	return true
end

local function send_next_chunk(caps, source, xfer_id, sent, size, chunk_size)
	local want = math.min(chunk_size, size - sent)
	local chunk, err = read_chunk(source, want)

	if err ~= nil then fail(caps, xfer_id, err, true) end
	if type(chunk) ~= 'string' or #chunk == 0 then fail(caps, xfer_id, 'short_source', true) end
	if sent + #chunk > size then fail(caps, xfer_id, 'source_overrun', true) end

	send_chunk(caps, xfer_id, sent, chunk)
	return sent + #chunk, {
		offset = sent,
		chunk = chunk,
	}
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

	local begin = construct('xfer_begin', protocol.xfer_begin,
		xfer_id, target, size, alg, digest, req.meta)

	send(caps, 'control', begin, 'transfer_begin_send_failed')

	local sent = 0
	local last_chunk = nil
	local state = 'waiting_ready'
	local deadline = fibers.now() + timeout_s

	while true do
		local which, item = fibers.perform(wait_frame_op(rx, deadline))
		if which == 'timeout' then fail(caps, xfer_id, 'timeout', true) end
		if item == nil then error('transfer_sender_frame_feed_closed', 0) end

		local frame = item.frame or item
		local handle_frame = type(frame) == 'table' and frame.xfer_id == xfer_id

		if handle_frame and frame.type == 'xfer_abort' then
			fail(caps, xfer_id, frame.err or 'remote_abort', false)

		elseif handle_frame and frame.type == 'xfer_ready' then
			if state == 'waiting_ready' then
				state = 'sending'
				deadline = fibers.now() + timeout_s
			end

		elseif handle_frame and frame.type == 'xfer_need' then
			if state ~= 'sending' then fail(caps, xfer_id, 'unexpected_need', true) end
			if frame.next ~= sent then
				if last_chunk
					and frame.next == last_chunk.offset
					and type(last_chunk.chunk) == 'string'
				then
					send_chunk(caps, xfer_id, last_chunk.offset, last_chunk.chunk)
					deadline = fibers.now() + timeout_s
				else
					fail(caps, xfer_id, ('unexpected_offset:next=%s sent=%s'):format(
						tostring(frame.next),
						tostring(sent)
					), true)
				end
			elseif sent >= size then
				state, deadline = send_commit(caps, xfer_id, size, alg, digest, timeout_s)
			else
				sent, last_chunk = send_next_chunk(caps, source, xfer_id, sent, size, chunk_size)
				deadline = fibers.now() + timeout_s
			end

		elseif handle_frame and frame.type == 'xfer_done' and state == 'committing' then
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

return M
