-- tests/unit/fabric/test_transfer_sender.lua
--
-- Contract tests for the doctrinal transfer sender worker.

local fibers  = require 'fibers'
local sleep   = require 'fibers.sleep'
local mailbox = require 'fibers.mailbox'
local op      = require 'fibers.op'

local transfer_sender = require 'services.fabric.transfer_sender'
local protocol        = require 'services.fabric.protocol'
local blob            = require 'devicecode.blob_source'
local queue           = require 'devicecode.support.queue'

local tests = {}

local function fail(msg)
	error(msg or 'assertion failed', 2)
end

local function assert_true(v, msg)
	if v ~= true then fail(msg or ('expected true, got ' .. tostring(v))) end
end

local function assert_eq(a, b, msg)
	if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end
end

local function assert_match(s, pat, msg)
	if type(s) ~= 'string' or not s:match(pat) then
		fail(msg or ('expected "' .. tostring(s) .. '" to match ' .. tostring(pat)))
	end
end

local function recv_with_timeout(rx, label, timeout)
	timeout = timeout or 0.25

	local which, item = fibers.perform(fibers.named_choice {
		item    = rx:recv_op(),
		timeout = sleep.sleep_op(timeout),
	})

	if which == 'timeout' then
		fail('timed out waiting for ' .. tostring(label or 'item'))
	end

	return item
end

local function send_frame(tx, frame)
	assert_true(tx:send({ frame = frame }))
end

local function make_sender_caps(control_tx, bulk_tx, frame_rx, opts)
	opts = opts or {}

	local function admit(tx, frame, label)
		return queue.try_admit_required(
			tx,
			{ kind = 'send_frame', at = fibers.now(), frame = frame },
			label or 'transfer_sender_test_send_failed'
		)
	end

	return {
		frame_rx   = frame_rx,
		chunk_size = opts.chunk_size or 3,
		timeout_s  = opts.timeout_s or 0.05,

		send_control_frame_now = function (frame, label)
			return admit(control_tx, frame, label)
		end,

		send_bulk_frame_now = function (frame, label)
			return admit(bulk_tx, frame, label)
		end,
	}
end

local function collect_result(req, driver, opts)
	opts = opts or {}
	local out = {}

	fibers.run(function ()
		local st, rep, value = fibers.run_scope(function (scope)
			local control_tx, control_rx = mailbox.new(opts.control_queue_len or 32, { full = 'reject_newest' })
			local bulk_tx, bulk_rx       = mailbox.new(opts.bulk_queue_len or 32, { full = 'reject_newest' })
			local frame_tx, frame_rx     = mailbox.new(opts.frame_queue_len or 32, { full = 'reject_newest' })

			out.control_rx = control_rx
			out.bulk_rx    = bulk_rx
			out.frame_tx   = frame_tx

			local ok, err = scope:spawn(function ()
				driver({
					control_rx = control_rx,
					bulk_rx    = bulk_rx,
					frame_tx   = frame_tx,
				})
			end)
			assert_true(ok, err)

			return transfer_sender.run(
				scope,
				req,
				make_sender_caps(control_tx, bulk_tx, frame_rx, opts)
			)
		end)

		out.status = st
		out.report = rep
		out.value  = value
	end)

	return out
end

local function make_req(overrides)
	overrides = overrides or {}

	local data = overrides.data
	if data == nil and overrides.source == nil then
		data = 'abcdef'
	end

	local source = overrides.source
	if source == nil and type(data) == 'string' then
		source = blob.from_string(data)
	end

	local size = overrides.size
	if size == nil and type(data) == 'string' then
		size = #data
	end

	local digest_data = overrides.digest_data
	if digest_data == nil and type(data) == 'string' then
		digest_data = data
	end
	if digest_data == nil then
		-- Source-backed tests that do not expose their bytes should set digest
		-- explicitly if the exact value matters. This default is only to satisfy
		-- the sender's xxhash32 request validation.
		digest_data = 'abcdef'
	end

	local req = {
		request_id = overrides.request_id or 'req-1',
		target     = overrides.target or 'remote.stage.main',
		source     = source,
		data       = data,
		size       = size,
		digest_alg = overrides.digest_alg or protocol.DIGEST_ALG,
		digest     = overrides.digest or protocol.digest_hex(digest_data),
		timeout_s  = overrides.timeout_s,
		xfer_id    = overrides.xfer_id,
		meta       = overrides.meta,
		metadata   = overrides.metadata,
	}

	for k, v in pairs(overrides) do
		req[k] = v
	end

	return req
end

function tests.test_sender_sends_begin_chunks_commit_and_returns_after_done()
	local seen = {}
	local req = make_req { data = 'abcdef', size = 6, xfer_id = 'xfer-1' }

	local out = collect_result(req, function (io)
		local begin = recv_with_timeout(io.control_rx, 'begin')
		assert_eq(begin.frame.type, 'xfer_begin')
		assert_eq(begin.frame.xfer_id, 'xfer-1')
		assert_eq(begin.frame.target, 'remote.stage.main')
		assert_eq(begin.frame.size, 6)
		assert_eq(begin.frame.digest_alg, protocol.DIGEST_ALG)
		assert_eq(begin.frame.digest, protocol.digest_hex('abcdef'))
		seen[#seen + 1] = begin.frame.type

		send_frame(io.frame_tx, assert(protocol.xfer_ready('xfer-1')))
		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-1', 0)))

		local chunk1 = recv_with_timeout(io.bulk_rx, 'chunk1')
		assert_eq(chunk1.frame.type, 'xfer_chunk')
		assert_eq(chunk1.frame.offset, 0)
		assert_eq(chunk1.frame.data, 'abc')
		assert_eq(chunk1.frame.chunk_digest, protocol.chunk_digest('abc'))
		seen[#seen + 1] = chunk1.frame.type

		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-1', 3)))

		local chunk2 = recv_with_timeout(io.bulk_rx, 'chunk2')
		assert_eq(chunk2.frame.offset, 3)
		assert_eq(chunk2.frame.data, 'def')
		assert_eq(chunk2.frame.chunk_digest, protocol.chunk_digest('def'))
		seen[#seen + 1] = chunk2.frame.type

		local commit = recv_with_timeout(io.control_rx, 'commit')
		assert_eq(commit.frame.type, 'xfer_commit')
		assert_eq(commit.frame.size, 6)
		assert_eq(commit.frame.digest_alg, protocol.DIGEST_ALG)
		assert_eq(commit.frame.digest, protocol.digest_hex('abcdef'))
		seen[#seen + 1] = commit.frame.type

		send_frame(io.frame_tx, assert(protocol.xfer_done('xfer-1')))
	end)

	assert_eq(out.status, 'ok', tostring(out.value))
	assert_eq(out.value.xfer_id, 'xfer-1')
	assert_eq(out.value.sent_bytes, 6)
	assert_eq(out.value.target, 'remote.stage.main')
	assert_eq(out.value.digest_alg, protocol.DIGEST_ALG)
	assert_eq(out.value.digest, protocol.digest_hex('abcdef'))
	assert_eq(seen[1], 'xfer_begin')
	assert_eq(seen[2], 'xfer_chunk')
	assert_eq(seen[3], 'xfer_chunk')
	assert_eq(seen[4], 'xfer_commit')
end

function tests.test_sender_timeout_sends_abort_and_fails_attempt()
	local req = make_req { data = 'abc', size = 3, xfer_id = 'xfer-timeout', timeout_s = 0.01 }

	local out = collect_result(req, function (io)
		local begin = recv_with_timeout(io.control_rx, 'begin')
		assert_eq(begin.frame.type, 'xfer_begin')
	end, { timeout_s = 0.01 })

	assert_eq(out.status, 'failed')
	assert_match(out.value, 'timeout')
end

function tests.test_sender_remote_abort_fails_without_echoing_abort()
	local req = make_req { data = 'abc', size = 3, xfer_id = 'xfer-abort' }

	local out = collect_result(req, function (io)
		recv_with_timeout(io.control_rx, 'begin')
		send_frame(io.frame_tx, assert(protocol.xfer_abort('xfer-abort', 'remote denied')))
	end)

	assert_eq(out.status, 'failed')
	assert_match(out.value, 'remote denied')
end

function tests.test_sender_unexpected_offset_sends_abort_and_fails()
	local req = make_req { data = 'abc', size = 3, xfer_id = 'xfer-offset' }

	local out = collect_result(req, function (io)
		recv_with_timeout(io.control_rx, 'begin')
		send_frame(io.frame_tx, assert(protocol.xfer_ready('xfer-offset')))
		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-offset', 1)))
	end)

	assert_eq(out.status, 'failed')
	assert_match(out.value, 'unexpected_offset')
end

function tests.test_sender_source_read_error_sends_abort_and_fails()
	local source = {
		read_chunk_op = function ()
			return op.always(nil, 'read boom')
		end,
	}

	local req = make_req {
		source = source,
		data = nil,
		size = 3,
		xfer_id = 'xfer-read-error',
		digest = protocol.digest_hex('abc'),
	}

	local out = collect_result(req, function (io)
		recv_with_timeout(io.control_rx, 'begin')
		send_frame(io.frame_tx, assert(protocol.xfer_ready('xfer-read-error')))
		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-read-error', 0)))
	end)

	assert_eq(out.status, 'failed')
	assert_match(out.value, 'read boom')
end

function tests.test_sender_does_not_close_source_itself()
	local source = blob.from_string('abc')
	local closed = 0

	function source:close(reason)
		closed = closed + 1
		self.close_reason = reason
		return true
	end

	local req = make_req {
		source = source,
		data = nil,
		size = 3,
		xfer_id = 'xfer-no-close',
		digest = protocol.digest_hex('abc'),
	}

	local out = collect_result(req, function (io)
		recv_with_timeout(io.control_rx, 'begin')
		send_frame(io.frame_tx, assert(protocol.xfer_ready('xfer-no-close')))
		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-no-close', 0)))
		recv_with_timeout(io.bulk_rx, 'chunk')
		recv_with_timeout(io.control_rx, 'commit')
		send_frame(io.frame_tx, assert(protocol.xfer_done('xfer-no-close')))
	end)

	assert_eq(out.status, 'ok', tostring(out.value))
	assert_eq(closed, 0)
end

function tests.test_sender_accepts_zero_byte_transfer_commit_after_need_zero()
	local req = make_req { data = '', size = 0, xfer_id = 'xfer-zero' }

	local out = collect_result(req, function (io)
		recv_with_timeout(io.control_rx, 'begin')
		send_frame(io.frame_tx, assert(protocol.xfer_ready('xfer-zero')))
		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-zero', 0)))

		local commit = recv_with_timeout(io.control_rx, 'commit')
		assert_eq(commit.frame.type, 'xfer_commit')
		assert_eq(commit.frame.size, 0)

		send_frame(io.frame_tx, assert(protocol.xfer_done('xfer-zero')))
	end)

	assert_eq(out.status, 'ok', tostring(out.value))
	assert_eq(out.value.sent_bytes, 0)
end

return tests
