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

local function capture_prints(fn)
	local old_print = _G.print
	local lines = {}
	_G.print = function (...)
		local parts = {}
		for i = 1, select('#', ...) do
			parts[#parts + 1] = tostring(select(i, ...))
		end
		lines[#lines + 1] = table.concat(parts, '\t')
	end
	local ok, err = pcall(fn, lines)
	_G.print = old_print
	if not ok then error(err, 0) end
	return lines
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
		trace_io   = opts.trace_io == true,

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
	}

	for k, v in pairs(overrides) do
		req[k] = v
	end

	return req
end

function tests.test_sender_sends_begin_chunks_commit_and_returns_after_done()
	local seen = {}
	local progress = {}
	local req = make_req {
		data = 'abcdef',
		size = 6,
		xfer_id = 'xfer-1',
		on_progress = function (p)
			progress[#progress + 1] = p
			return true
		end,
	}

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

		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-1', 6)))

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
	assert_eq(progress[1].status, 'waiting_ready')
	assert_eq(progress[1].sent, 0)
	assert_eq(progress[2].status, 'sending')
	assert_eq(progress[2].sent, 3)
	assert_eq(progress[3].status, 'sending')
	assert_eq(progress[3].sent, 6)
end

function tests.test_sender_retries_begin_while_waiting_ready_and_then_completes()
	local progress = {}
	local req = make_req {
		data = 'abc',
		size = 3,
		xfer_id = 'xfer-begin-retry',
		timeout_s = 2.5,
		on_progress = function (p)
			progress[#progress + 1] = p
			return true
		end,
	}

	local out = collect_result(req, function (io)
		local begin1 = recv_with_timeout(io.control_rx, 'begin')
		assert_eq(begin1.frame.type, 'xfer_begin')
		assert_eq(begin1.frame.xfer_id, 'xfer-begin-retry')
		assert_eq(queue.try_recv_now(io.bulk_rx), nil, 'sender must not send bulk before xfer_ready')

		local begin2 = recv_with_timeout(io.control_rx, 'begin retry', 1.3)
		assert_eq(begin2.frame.type, 'xfer_begin')
		assert_eq(begin2.frame.xfer_id, 'xfer-begin-retry')
		assert_eq(queue.try_recv_now(io.bulk_rx), nil, 'retry must not send bulk before xfer_ready')

		send_frame(io.frame_tx, assert(protocol.xfer_ready('xfer-begin-retry')))
		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-begin-retry', 0)))

		local chunk = recv_with_timeout(io.bulk_rx, 'chunk after ready')
		assert_eq(chunk.frame.type, 'xfer_chunk')
		assert_eq(chunk.frame.offset, 0)
		assert_eq(chunk.frame.data, 'abc')

		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-begin-retry', 3)))
		local commit = recv_with_timeout(io.control_rx, 'commit')
		assert_eq(commit.frame.type, 'xfer_commit')
		send_frame(io.frame_tx, assert(protocol.xfer_done('xfer-begin-retry')))
	end, { timeout_s = 2.5 })

	assert_eq(out.status, 'ok', tostring(out.value))
	assert_eq(out.value.sent_bytes, 3)
	assert_eq(progress[1].status, 'waiting_ready')
	assert_eq(progress[1].sent, 0)
	assert_eq(progress[2].status, 'waiting_ready')
	assert_eq(progress[2].sent, 0)
	assert_eq(progress[3].status, 'sending')
	assert_eq(progress[3].sent, 3)
end

function tests.test_sender_treats_need_zero_as_implicit_ready()
	local req = make_req {
		data = 'abc',
		size = 3,
		xfer_id = 'xfer-implicit-ready',
		timeout_s = 0.2,
	}

	local out = collect_result(req, function (io)
		recv_with_timeout(io.control_rx, 'begin')

		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-implicit-ready', 0)))
		local chunk = recv_with_timeout(io.bulk_rx, 'chunk after implicit ready')
		assert_eq(chunk.frame.type, 'xfer_chunk')
		assert_eq(chunk.frame.offset, 0)
		assert_eq(chunk.frame.data, 'abc')

		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-implicit-ready', 3)))
		local commit = recv_with_timeout(io.control_rx, 'commit')
		assert_eq(commit.frame.type, 'xfer_commit')
		send_frame(io.frame_tx, assert(protocol.xfer_done('xfer-implicit-ready')))
	end, { timeout_s = 0.2 })

	assert_eq(out.status, 'ok', tostring(out.value))
	assert_eq(out.value.sent_bytes, 3)
end

function tests.test_sender_rejects_nonzero_need_while_waiting_ready()
	local req = make_req {
		data = 'abc',
		size = 3,
		xfer_id = 'xfer-waiting-ready-bad-need',
		timeout_s = 0.2,
	}

	local out = collect_result(req, function (io)
		recv_with_timeout(io.control_rx, 'begin')
		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-waiting-ready-bad-need', 1)))
	end, { timeout_s = 0.2 })

	assert_eq(out.status, 'failed')
	assert_match(out.value, 'unexpected_need')
end

function tests.test_sender_trace_logs_are_quiet_by_default_and_enabled_by_flag()
	local function run_once(trace_io)
		local req = make_req {
			data = 'abc',
			size = 3,
			xfer_id = trace_io and 'xfer-trace-on' or 'xfer-trace-off',
		}

		return capture_prints(function ()
			local out = collect_result(req, function (io)
				recv_with_timeout(io.control_rx, 'begin')
				send_frame(io.frame_tx, assert(protocol.xfer_ready(req.xfer_id)))
				send_frame(io.frame_tx, assert(protocol.xfer_need(req.xfer_id, 0)))
				recv_with_timeout(io.bulk_rx, 'chunk')
				send_frame(io.frame_tx, assert(protocol.xfer_need(req.xfer_id, 3)))
				recv_with_timeout(io.control_rx, 'commit')
				send_frame(io.frame_tx, assert(protocol.xfer_done(req.xfer_id)))
			end, { trace_io = trace_io })

			assert_eq(out.status, 'ok', tostring(out.value))
		end)
	end

	local quiet = run_once(false)
	assert_eq(#quiet, 0)

	local noisy = run_once(true)
	assert_true(#noisy > 0, 'trace_io=true should enable transfer diagnostics')
	assert_match(noisy[1], '%[fabric%-xfer%-tx%]')
end

function tests.test_sender_resends_cached_chunk_when_receiver_reasks_same_offset_after_delay()
	local req = make_req {
		data = 'abcdef',
		size = 6,
		xfer_id = 'xfer-retry',
		timeout_s = 1.0,
	}

	local out = collect_result(req, function (io)
		recv_with_timeout(io.control_rx, 'begin')
		send_frame(io.frame_tx, assert(protocol.xfer_ready('xfer-retry')))
		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-retry', 0)))

		local chunk1 = recv_with_timeout(io.bulk_rx, 'chunk1')
		assert_eq(chunk1.frame.offset, 0)
		assert_eq(chunk1.frame.data, 'abc')

		-- Same offset means the receiver did not advance. The sender must
		-- resend the cached frame without reading from the source again once
		-- the previous copy has had time to leave the host.
		fibers.perform(sleep.sleep_op(0.3))
		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-retry', 0)))
		local retry1 = recv_with_timeout(io.bulk_rx, 'chunk1 retry')
		assert_eq(retry1.frame.offset, 0)
		assert_eq(retry1.frame.data, 'abc')

		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-retry', 3)))
		local chunk2 = recv_with_timeout(io.bulk_rx, 'chunk2')
		assert_eq(chunk2.frame.offset, 3)
		assert_eq(chunk2.frame.data, 'def')

		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-retry', 6)))
		local commit = recv_with_timeout(io.control_rx, 'commit')
		assert_eq(commit.frame.type, 'xfer_commit')
		send_frame(io.frame_tx, assert(protocol.xfer_done('xfer-retry')))
	end, { timeout_s = 1.0 })

	assert_eq(out.status, 'ok', tostring(out.value))
	assert_eq(out.value.sent_bytes, 6)
	assert_eq(out.value.retransmits, 1)
end

function tests.test_sender_coalesces_immediate_duplicate_need_for_pending_offset()
	local req = make_req {
		data = 'abcdef',
		size = 6,
		xfer_id = 'xfer-coalesce',
		timeout_s = 0.2,
	}

	local out = collect_result(req, function (io)
		recv_with_timeout(io.control_rx, 'begin')
		send_frame(io.frame_tx, assert(protocol.xfer_ready('xfer-coalesce')))
		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-coalesce', 0)))
		fibers.perform(sleep.sleep_op(0.01))

		-- A duplicate request that arrives immediately after the original send
		-- should not enqueue an identical chunk while the first copy is still
		-- queued or on the wire.
		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-coalesce', 0)))
		fibers.perform(sleep.sleep_op(0.01))

		local chunk1 = recv_with_timeout(io.bulk_rx, 'chunk1')
		assert_eq(chunk1.frame.offset, 0)
		assert_eq(queue.try_recv_now(io.bulk_rx), nil, 'duplicate need should be coalesced')

		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-coalesce', 3)))
		local chunk2 = recv_with_timeout(io.bulk_rx, 'chunk2')
		assert_eq(chunk2.frame.offset, 3)

		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-coalesce', 6)))
		local commit = recv_with_timeout(io.control_rx, 'commit')
		assert_eq(commit.frame.type, 'xfer_commit')
		send_frame(io.frame_tx, assert(protocol.xfer_done('xfer-coalesce')))
	end, { timeout_s = 0.2 })

	assert_eq(out.status, 'ok', tostring(out.value))
	assert_eq(out.value.sent_bytes, 6)
	assert_eq(out.value.retransmits, 0)
end

function tests.test_sender_waits_for_transient_bulk_queue_backpressure()
	local req = make_req {
		data = 'abcdef',
		size = 6,
		xfer_id = 'xfer-backpressure',
		timeout_s = 0.2,
	}

	local out = collect_result(req, function (io)
		recv_with_timeout(io.control_rx, 'begin')
		send_frame(io.frame_tx, assert(protocol.xfer_ready('xfer-backpressure')))
		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-backpressure', 0)))

		fibers.perform(sleep.sleep_op(0.02))
		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-backpressure', 3)))
		fibers.perform(sleep.sleep_op(0.02))

		local chunk1 = recv_with_timeout(io.bulk_rx, 'queued chunk1')
		assert_eq(chunk1.frame.offset, 0)

		local chunk2 = recv_with_timeout(io.bulk_rx, 'chunk2 after backpressure')
		assert_eq(chunk2.frame.offset, 3)

		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-backpressure', 6)))
		local commit = recv_with_timeout(io.control_rx, 'commit')
		assert_eq(commit.frame.type, 'xfer_commit')
		send_frame(io.frame_tx, assert(protocol.xfer_done('xfer-backpressure')))
	end, {
		bulk_queue_len = 1,
		timeout_s = 0.2,
	})

	assert_eq(out.status, 'ok', tostring(out.value))
	assert_eq(out.value.sent_bytes, 6)
end

function tests.test_sender_ignores_stale_need_for_already_advanced_offset()
	local req = make_req { data = 'abcdefghi', size = 9, xfer_id = 'xfer-stale' }

	local out = collect_result(req, function (io)
		recv_with_timeout(io.control_rx, 'begin')
		send_frame(io.frame_tx, assert(protocol.xfer_ready('xfer-stale')))
		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-stale', 0)))

		local chunk1 = recv_with_timeout(io.bulk_rx, 'chunk1')
		assert_eq(chunk1.frame.offset, 0)
		assert_eq(chunk1.frame.data, 'abc')

		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-stale', 3)))
		local chunk2 = recv_with_timeout(io.bulk_rx, 'chunk2')
		assert_eq(chunk2.frame.offset, 3)
		assert_eq(chunk2.frame.data, 'def')

		-- A delayed duplicate for an already accepted offset must not abort the
		-- transfer or rewind the source. The current pending chunk remains 3..6.
		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-stale', 0)))

		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-stale', 6)))
		local chunk3 = recv_with_timeout(io.bulk_rx, 'chunk3')
		assert_eq(chunk3.frame.offset, 6)
		assert_eq(chunk3.frame.data, 'ghi')

		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-stale', 9)))
		local commit = recv_with_timeout(io.control_rx, 'commit')
		assert_eq(commit.frame.type, 'xfer_commit')
		send_frame(io.frame_tx, assert(protocol.xfer_done('xfer-stale')))
	end)

	assert_eq(out.status, 'ok', tostring(out.value))
	assert_eq(out.value.sent_bytes, 9)
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

function tests.test_sender_waiting_ready_timeout_reports_begin_attempts()
	local req = make_req {
		data = 'abc',
		size = 3,
		xfer_id = 'xfer-waiting-ready-timeout',
		timeout_s = 10,
		begin_retry_interval_s = 0.01,
		begin_max_attempts = 3,
		begin_startup_timeout_s = 0.05,
	}

	local out = collect_result(req, function (io)
		local begin1 = recv_with_timeout(io.control_rx, 'begin')
		assert_eq(begin1.frame.type, 'xfer_begin')

		local begin2 = recv_with_timeout(io.control_rx, 'begin retry 2', 0.1)
		assert_eq(begin2.frame.type, 'xfer_begin')
		assert_eq(begin2.frame.xfer_id, 'xfer-waiting-ready-timeout')

		local begin3 = recv_with_timeout(io.control_rx, 'begin retry 3', 0.1)
		assert_eq(begin3.frame.type, 'xfer_begin')
		assert_eq(begin3.frame.xfer_id, 'xfer-waiting-ready-timeout')
		assert_eq(queue.try_recv_now(io.bulk_rx), nil, 'waiting_ready timeout must not send bulk')
	end, { timeout_s = 10 })

	assert_eq(out.status, 'failed')
	assert_match(out.value, 'waiting_ready_timeout')
	assert_match(out.value, 'state=waiting_ready')
	assert_match(out.value, 'sent=0')
	assert_match(out.value, 'begin_attempts=3')
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

function tests.test_sender_recovers_from_future_need_before_pending_chunk()
	local req = make_req { data = 'abc', size = 3, xfer_id = 'xfer-future-need' }

	local out = collect_result(req, function (io)
		recv_with_timeout(io.control_rx, 'begin')
		send_frame(io.frame_tx, assert(protocol.xfer_ready('xfer-future-need')))
		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-future-need', 1)))

		local chunk = recv_with_timeout(io.bulk_rx, 'chunk after future need')
		assert_eq(chunk.frame.type, 'xfer_chunk')
		assert_eq(chunk.frame.offset, 0)
		assert_eq(chunk.frame.data, 'abc')

		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-future-need', 3)))
		local commit = recv_with_timeout(io.control_rx, 'commit')
		assert_eq(commit.frame.type, 'xfer_commit')
		send_frame(io.frame_tx, assert(protocol.xfer_done('xfer-future-need')))
	end)

	assert_eq(out.status, 'ok', tostring(out.value))
	assert_eq(out.value.sent_bytes, 3)
end

function tests.test_sender_recovers_from_future_need_while_chunk_pending()
	local req = make_req { data = 'abcdef', size = 6, xfer_id = 'xfer-pending-future' }

	local out = collect_result(req, function (io)
		recv_with_timeout(io.control_rx, 'begin')
		send_frame(io.frame_tx, assert(protocol.xfer_ready('xfer-pending-future')))
		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-pending-future', 0)))

		local chunk1 = recv_with_timeout(io.bulk_rx, 'chunk1')
		assert_eq(chunk1.frame.offset, 0)
		assert_eq(chunk1.frame.data, 'abc')

		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-pending-future', 6)))
		assert_eq(queue.try_recv_now(io.bulk_rx), nil, 'future need should be coalesced while pending')

		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-pending-future', 3)))
		local chunk2 = recv_with_timeout(io.bulk_rx, 'chunk2 after recovery')
		assert_eq(chunk2.frame.offset, 3)
		assert_eq(chunk2.frame.data, 'def')

		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-pending-future', 6)))
		local commit = recv_with_timeout(io.control_rx, 'commit')
		assert_eq(commit.frame.type, 'xfer_commit')
		send_frame(io.frame_tx, assert(protocol.xfer_done('xfer-pending-future')))
	end)

	assert_eq(out.status, 'ok', tostring(out.value))
	assert_eq(out.value.sent_bytes, 6)
end

function tests.test_sender_resends_commit_on_duplicate_need_size_after_interval()
	local req = make_req {
		data = 'abc',
		size = 3,
		xfer_id = 'xfer-commit-resend',
		timeout_s = 1.0,
	}

	local out = collect_result(req, function (io)
		recv_with_timeout(io.control_rx, 'begin')
		send_frame(io.frame_tx, assert(protocol.xfer_ready('xfer-commit-resend')))
		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-commit-resend', 0)))
		recv_with_timeout(io.bulk_rx, 'chunk')

		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-commit-resend', 3)))
		local commit1 = recv_with_timeout(io.control_rx, 'commit')
		assert_eq(commit1.frame.type, 'xfer_commit')

		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-commit-resend', 3)))
		fibers.perform(sleep.sleep_op(0.01))
		assert_eq(queue.try_recv_now(io.control_rx), nil, 'immediate duplicate commit need should be coalesced')

		fibers.perform(sleep.sleep_op(0.3))
		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-commit-resend', 3)))
		local commit2 = recv_with_timeout(io.control_rx, 'commit retry')
		assert_eq(commit2.frame.type, 'xfer_commit')
		assert_eq(commit2.frame.xfer_id, 'xfer-commit-resend')

		send_frame(io.frame_tx, assert(protocol.xfer_done('xfer-commit-resend')))
	end, { timeout_s = 1.0 })

	assert_eq(out.status, 'ok', tostring(out.value))
	assert_eq(out.value.sent_bytes, 3)
	assert_eq(out.value.commit_resends, 1)
end

function tests.test_sender_ignores_stale_need_while_committing()
	local req = make_req {
		data = 'abc',
		size = 3,
		xfer_id = 'xfer-commit-stale-need',
		timeout_s = 0.2,
	}

	local out = collect_result(req, function (io)
		recv_with_timeout(io.control_rx, 'begin')
		send_frame(io.frame_tx, assert(protocol.xfer_ready('xfer-commit-stale-need')))
		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-commit-stale-need', 0)))
		recv_with_timeout(io.bulk_rx, 'chunk')

		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-commit-stale-need', 3)))
		local commit = recv_with_timeout(io.control_rx, 'commit')
		assert_eq(commit.frame.type, 'xfer_commit')

		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-commit-stale-need', 0)))
		fibers.perform(sleep.sleep_op(0.01))
		assert_eq(queue.try_recv_now(io.control_rx), nil, 'stale commit need should not resend commit')

		send_frame(io.frame_tx, assert(protocol.xfer_done('xfer-commit-stale-need')))
	end, { timeout_s = 0.2 })

	assert_eq(out.status, 'ok', tostring(out.value))
	assert_eq(out.value.sent_bytes, 3)
	assert_eq(out.value.commit_resends, 0)
end

function tests.test_sender_future_need_while_committing_times_out_without_refresh()
	local req = make_req {
		data = 'abc',
		size = 3,
		xfer_id = 'xfer-commit-future-need',
		timeout_s = 0.06,
	}

	local out = collect_result(req, function (io)
		recv_with_timeout(io.control_rx, 'begin')
		send_frame(io.frame_tx, assert(protocol.xfer_ready('xfer-commit-future-need')))
		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-commit-future-need', 0)))
		recv_with_timeout(io.bulk_rx, 'chunk')

		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-commit-future-need', 3)))
		local commit = recv_with_timeout(io.control_rx, 'commit')
		assert_eq(commit.frame.type, 'xfer_commit')

		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-commit-future-need', 6)))
	end, { timeout_s = 0.06 })

	assert_eq(out.status, 'failed')
	assert_match(out.value, 'timeout')
	assert_match(out.value, 'state=committing')
	assert_match(out.value, 'last_need_next=6')
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
		send_frame(io.frame_tx, assert(protocol.xfer_need('xfer-no-close', 3)))
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


function tests.test_sender_does_not_send_first_chunk_implicitly_after_ready()
	local req = make_req { data = 'abc', size = 3, xfer_id = 'xfer-demand-driven', timeout_s = 0.03 }

	local out = collect_result(req, function (io)
		recv_with_timeout(io.control_rx, 'begin')
		send_frame(io.frame_tx, assert(protocol.xfer_ready('xfer-demand-driven')))

		local which = fibers.perform(fibers.named_choice {
			bulk    = io.bulk_rx:recv_op(),
			timeout = sleep.sleep_op(0.01),
		})
		assert_eq(which, 'timeout', 'sender must wait for xfer_need before sending bulk')
	end, { timeout_s = 0.03 })

	assert_eq(out.status, 'failed')
	assert_match(out.value, 'timeout')
end

return tests
