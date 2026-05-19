-- services/fabric/transfer_receive.lua
--
-- Receive-side Fabric transfer worker.
--
-- This is deliberately below the public bus surface. Fabric owns the wire
-- transfer protocol; application services register target objects at runtime.
-- A target receives a complete stream through a finaliser-safe sink interface.

local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'

local protocol = require 'services.fabric.protocol'
local xxhash32 = require 'shared.hash.xxhash32'

local M = {}

local DEFAULT_TIMEOUT = 1.0

local function positive(v, fallback, name)
	v = v or fallback
	if type(v) ~= 'number' or v <= 0 or v ~= v or v == math.huge or v == -math.huge then
		error('transfer_receive: ' .. name .. ' must be positive', 0)
	end
	return v
end

local function construct(label, fn, ...)
	local frame, err = fn(...)
	if not frame then error(label .. ': ' .. tostring(err), 0) end
	return frame
end

local function send_control(caps, frame, label)
	local fn = caps.send_control_frame_now
	if type(fn) ~= 'function' then
		error('transfer_receive: missing session-bound control sender', 0)
	end
	local ok, err = fn(frame, label)
	if ok ~= true then error((label or 'transfer_receive_send_failed') .. ': ' .. tostring(err), 0) end
	return true
end

local function try_abort(caps, xfer_id, reason)
	if type(caps.send_control_frame_now) ~= 'function' then return true, nil end
	local frame, err = protocol.xfer_abort(xfer_id, tostring(reason or 'aborted'))
	if not frame then return nil, err end
	return caps.send_control_frame_now(frame, 'transfer_receive_abort_send_failed')
end

local function terminate_sink(sink, reason)
	if type(sink) ~= 'table' then return true, nil end
	if type(sink.abort) == 'function' then return sink:abort(reason or 'transfer_aborted') end
	if type(sink.terminate) == 'function' then return sink:terminate(reason or 'transfer_aborted') end
	if type(sink.close) == 'function' then return sink:close(reason or 'transfer_aborted') end
	return true, nil
end

local function fail(caps, xfer_id, sink, reason, send_abort)
	local err = tostring(reason or 'transfer_receive_failed')
	terminate_sink(sink, err)
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

local function open_sink(target, req)
	local sink, err
	if type(target.open_sink_op) == 'function' then
		sink, err = fibers.perform(target:open_sink_op(req))
	elseif type(target.create_sink_op) == 'function' then
		sink, err = fibers.perform(target:create_sink_op(req))
	elseif type(target.begin_transfer_op) == 'function' then
		sink, err = fibers.perform(target:begin_transfer_op(req))
	elseif type(target.open_sink) == 'function' then
		sink, err = target:open_sink(req)
	elseif type(target.create_sink) == 'function' then
		sink, err = target:create_sink(req)
	end
	if sink == nil then return nil, err or 'transfer_target_unavailable' end
	if type(sink) ~= 'table' then return nil, 'transfer_target_returned_non_sink' end
	if type(sink.append_op) ~= 'function'
		and type(sink.write_chunk_op) ~= 'function'
		and type(sink.write_op) ~= 'function'
	then
		return nil, 'transfer_sink_missing_append_op'
	end
	if type(sink.commit_op) ~= 'function' then
		return nil, 'transfer_sink_missing_commit_op'
	end
	return sink, nil
end

local function append_chunk(sink, chunk)
	local ok, err
	if type(sink.append_op) == 'function' then
		ok, err = fibers.perform(sink:append_op(chunk))
	elseif type(sink.write_chunk_op) == 'function' then
		ok, err = fibers.perform(sink:write_chunk_op(chunk))
	else
		ok, err = fibers.perform(sink:write_op(chunk))
	end
	if ok == nil or ok == false then return nil, err or 'write_failed' end
	return true, nil
end

local function commit_sink(sink, req)
	local result, err = fibers.perform(sink:commit_op(req))
	if result == nil or result == false then return nil, err or 'commit_failed' end
	return result, nil
end

local function require_begin(req)
	local begin = req.initial_frame
	if type(begin) ~= 'table' or begin.type ~= 'xfer_begin' then
		error('transfer_receive: initial xfer_begin required', 0)
	end
	if begin.digest_alg ~= protocol.DIGEST_ALG then
		error('unsupported_digest_alg', 0)
	end
	if type(begin.digest) ~= 'string' or not protocol.digest_ok(begin.digest) then
		error('invalid_digest', 0)
	end
	return begin
end

function M.run(scope, req, caps)
	if type(scope) ~= 'table' then error('transfer_receive.run: scope required', 2) end
	if type(req) ~= 'table' then error('transfer_receive.run: request table required', 2) end
	if type(caps) ~= 'table' then error('transfer_receive.run: caps table required', 2) end
	local rx = caps.frame_rx
	if type(rx) ~= 'table' or type(rx.recv_op) ~= 'function' then
		error('transfer_receive: frame_rx required', 0)
	end

	local begin = require_begin(req)
	local xfer_id = begin.xfer_id
	local target_id = begin.target
	local size = begin.size
	local timeout_s = positive(req.timeout_s or caps.timeout_s, DEFAULT_TIMEOUT, 'timeout_s')
	local target = req.target
	if type(target) ~= 'table' then
		fail(caps, xfer_id, nil, 'unsupported_target', true)
	end

	local sink, serr = open_sink(target, {
		xfer_id = xfer_id,
		target = target_id,
		size = size,
		digest_alg = begin.digest_alg,
		digest = begin.digest,
		meta = protocol.copy_json_value(begin.meta),
		session = req.session,
	})
	if sink == nil then
		fail(caps, xfer_id, nil, serr or 'transfer_target_unavailable', true)
	end

	local finished = false
	scope:finally(function (_, status, primary)
		if not finished then
			terminate_sink(sink, primary or status or 'transfer_receive_closed')
		end
	end)

	send_control(caps, construct('xfer_ready', protocol.xfer_ready, xfer_id), 'transfer_receive_ready_send_failed')
	send_control(caps, construct('xfer_need', protocol.xfer_need, xfer_id, 0), 'transfer_receive_need_send_failed')

	local received = 0
	local digest_state = xxhash32.new(0)
	local deadline = fibers.now() + timeout_s

	while true do
		local which, item = fibers.perform(wait_frame_op(rx, deadline))
		if which == 'timeout' then fail(caps, xfer_id, sink, 'timeout', true) end
		if item == nil then fail(caps, xfer_id, sink, 'transfer_receive_frame_feed_closed', false) end
		local frame = item.frame or item

		if type(frame) ~= 'table' or frame.xfer_id ~= xfer_id then
			-- Manager normally filters these.

		elseif frame.type == 'xfer_abort' then
			fail(caps, xfer_id, sink, frame.err or 'remote_abort', false)

		elseif frame.type == 'xfer_chunk' then
			if frame.offset ~= received then fail(caps, xfer_id, sink, 'unexpected_offset', true) end
			local chunk = frame.data
			if type(chunk) ~= 'string' then fail(caps, xfer_id, sink, 'invalid_chunk_data', true) end
			if received + #chunk > size then fail(caps, xfer_id, sink, 'size_overrun', true) end
			if not protocol.verify_chunk_digest(chunk, frame.chunk_digest) then
				fail(caps, xfer_id, sink, 'chunk_digest_mismatch', true)
			end
			local ok, werr = append_chunk(sink, chunk)
			if ok ~= true then fail(caps, xfer_id, sink, werr or 'write_failed', true) end
			xxhash32.update(digest_state, chunk)
			received = received + #chunk
			deadline = fibers.now() + timeout_s
			-- Acknowledge every accepted chunk, including the final one.  The
			-- sender waits for xfer_need next == size before sending xfer_commit.
			-- This keeps commit ordered after the receiver has actually processed
			-- the last bulk frame, even when the writer uses separate control and
			-- bulk lanes.
			send_control(caps, construct('xfer_need', protocol.xfer_need, xfer_id, received), 'transfer_receive_need_send_failed')

		elseif frame.type == 'xfer_commit' then
			if frame.size ~= size or frame.size ~= received then
				fail(caps, xfer_id, sink, 'short_transfer', true)
			end
			if frame.digest_alg ~= protocol.DIGEST_ALG then
				fail(caps, xfer_id, sink, 'unsupported_digest_alg', true)
			end
			local got = xxhash32.digest_hex_state(digest_state)
			if frame.digest ~= begin.digest or frame.digest ~= got then
				fail(caps, xfer_id, sink, 'digest_mismatch', true)
			end
			local commit_result, cerr = commit_sink(sink, {
				xfer_id = xfer_id,
				target = target_id,
				size = size,
				digest_alg = frame.digest_alg,
				digest = frame.digest,
				meta = protocol.copy_json_value(begin.meta),
				session = req.session,
			})
			if commit_result == nil then fail(caps, xfer_id, sink, cerr or 'commit_failed', true) end
			finished = true
			send_control(caps, construct('xfer_done', protocol.xfer_done, xfer_id), 'transfer_receive_done_send_failed')
			return {
				target = target_id,
				xfer_id = xfer_id,
				digest_alg = frame.digest_alg,
				digest = frame.digest,
				received_bytes = received,
				size = size,
				commit_result = commit_result,
			}
		end
	end
end

return M
