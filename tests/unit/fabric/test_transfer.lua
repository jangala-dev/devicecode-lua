-- tests/unit/fabric/test_transfer.lua
--
-- Tests for the transfer manager after removing injected attempt callbacks.

local fibers  = require 'fibers'
local sleep   = require 'fibers.sleep'
local mailbox = require 'fibers.mailbox'

local transfer = require 'services.fabric.transfer'
local session  = require 'services.fabric.session'
local protocol = require 'services.fabric.protocol'
local queue    = require 'devicecode.support.queue'
local resource = require 'devicecode.support.resource'
local blob     = require 'devicecode.blob_source'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_true(v, msg) if v ~= true then fail(msg or ('expected true, got ' .. tostring(v))) end end
local function assert_nil(v, msg) if v ~= nil then fail(msg or ('expected nil, got ' .. tostring(v))) end end
local function assert_not_nil(v, msg) if v == nil then fail(msg or 'expected non-nil value') end end
local function assert_eq(a, b, msg)
	if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end
end

local function recv_with_timeout(rx, label, timeout)
	timeout = timeout or 0.25
	local which, item = fibers.perform(fibers.named_choice{
		item = rx:recv_op(),
		timeout = sleep.sleep_op(timeout),
	})
	if which == 'timeout' then fail('timed out waiting for ' .. tostring(label or 'item')) end
	return item
end

local function wait_transfer_last_status(h, wanted, label, timeout)
	timeout = timeout or 0.25
	local deadline = fibers.now() + timeout
	while fibers.now() < deadline do
		local remaining = deadline - fibers.now()
		local which, ev = fibers.perform(fibers.named_choice{
			event = h.state_rx:recv_op(),
			timeout = sleep.sleep_op(remaining),
		})
		if which == 'timeout' then break end
		local snap = ev and ev.snapshot
		local last = snap and snap.last
		if last and last.status == wanted then
			return snap
		end
	end
	fail('timed out waiting for transfer last status ' .. tostring(wanted) .. ' for ' .. tostring(label or 'transfer'))
end

local function ctx(gen, sid)
	return session.new_session_context {
		link_id = 'link-a',
		link_generation = 1,
		session_generation = gen or 1,
		peer_sid = sid or 'sid-1',
		peer_node = 'mcu',
		proto = protocol.PROTO,
	}
end

local function peer_session_event(gen, sid)
	return { kind = 'peer_session', session = ctx(gen, sid), at = fibers.now() }
end

local function transfer_frame_event(frame, gen, sid)
	return { kind = 'session_frame', lane = 'transfer', session = ctx(gen, sid), frame = frame, at = fibers.now() }
end

local function slot_request(id)
	local r = { request_id = id or 'req-1', request_generation = 1, xfer_id = 'xfer-1', result = nil }
	function r:reply(v) self.result = { ok = true, value = v }; return true end
	function r:fail(e) self.result = { ok = false, err = e }; return true end
	return r
end

local function start_manager(scope, opts)
	opts = opts or {}
	local admission_tx, admission_rx = mailbox.new(8, { full = 'reject_newest' })
	local session_tx, session_rx = mailbox.new(32, { full = 'reject_newest' })
	local state_tx, state_rx = mailbox.new(32, { full = 'reject_newest' })
	local outbound_control_tx, outbound_control_rx = mailbox.new(32, { full = 'reject_newest' })
	local outbound_rpc_tx, outbound_rpc_rx = mailbox.new(32, { full = 'reject_newest' })
	local outbound_bulk_tx, outbound_bulk_rx = mailbox.new(32, { full = 'reject_newest' })
	local outbound = session.new_outbound_gate {
		tx_control = outbound_control_tx,
		tx_rpc = outbound_rpc_tx,
		tx_bulk = outbound_bulk_tx,
	}
	local done_tx, done_rx = mailbox.new(1, { full = 'reject_newest' })

	local ok, err = scope:spawn(function ()
		local result = transfer.run(scope, {
			manager_id = 'transfer-test',
			link_id = 'link-a',
			link_generation = 1,
			admission_rx = admission_rx,
			session_rx = session_rx,
			outbound = outbound,
			state_tx = state_tx,
			chunk_size = opts.chunk_size or 3,
			timeout_s = opts.timeout_s or 0.05,
			retry_limit = opts.retry_limit,
			receive_targets = opts.receive_targets,
		})
		queue.try_admit_required(done_tx, result, 'transfer_done')
	end)
	assert_true(ok, err)

	return {
		admission_tx = admission_tx,
		session_tx = session_tx,
		state_rx = state_rx,
		control_rx = outbound_control_rx,
		rpc_rx = outbound_rpc_rx,
		bulk_rx = outbound_bulk_rx,
		outbound = outbound,
		done_rx = done_rx,
	}
end

function tests.test_reducer_requires_session_context_for_claims()
	local state = transfer.new_state { manager_id = 'm' }
	local ok, err = pcall(function ()
		transfer.claim_slot(state, { request_id = 'r1', request_generation = 1 })
	end)
	assert_eq(ok, false)
	assert_not_nil(err)

	local accepted = transfer.claim_slot(state, {
		request_id = 'r1',
		request_generation = 1,
		session = ctx(),
		xfer_id = 'xfer-1',
	})
	assert_eq(accepted, true)
	assert_eq(transfer.snapshot(state).active.session.peer_sid, 'sid-1')
end

function tests.test_reducer_tracks_active_send_progress()
	local state = transfer.new_state { manager_id = 'm' }
	assert_true(transfer.claim_slot(state, {
		request_id = 'r-progress',
		request_generation = 1,
		session = ctx(),
		xfer_id = 'xfer-progress',
		size = 6,
	}))

	local ok, err = transfer.apply_progress(state, {
		request_id = 'r-progress',
		request_generation = 1,
		session = ctx(),
		xfer_id = 'xfer-progress',
		sent = 3,
		size = 6,
		status = 'sending',
		chunk_size = 3,
		pending_offset = 3,
		pending_next = 6,
		last_transfer_event = 'chunk_tx',
	})
	assert_true(ok, err)
	local snap = transfer.snapshot(state)
	assert_eq(snap.active.sent, 3)
	assert_eq(snap.active.size, 6)
	assert_eq(snap.active.status, 'sending')
	assert_eq(snap.active.chunk_size, 3)
	assert_eq(snap.active.pending_offset, 3)
	assert_eq(snap.active.pending_next, 6)
	assert_eq(snap.active.last_transfer_event, 'chunk_tx')
end

function tests.test_slot_admission_without_session_fails_request()
	fibers.run(function (scope)
		local h = start_manager(scope)
		local req = slot_request('req-nosession')
		assert_true(h.admission_tx:send(req))
		local deadline = fibers.now() + 0.1
		while req.result == nil and fibers.now() < deadline do fibers.perform(sleep.sleep_op(0.001)) end
		assert_eq(req.result.ok, false)
		assert_eq(req.result.err, 'no_session')
		h.admission_tx:close('done')
		h.session_tx:close('done')
		recv_with_timeout(h.done_rx, 'manager done')
	end)
end

function tests.test_slot_admission_grants_lease_and_release_clears_slot()
	fibers.run(function (scope)
		local h = start_manager(scope)
		local c = ctx()
		h.outbound:bind(c)
		assert_true(h.session_tx:send(peer_session_event()))
		local req = slot_request('req-lease')
		assert_true(h.admission_tx:send(req))
		local deadline = fibers.now() + 0.1
		while req.result == nil and fibers.now() < deadline do fibers.perform(sleep.sleep_op(0.001)) end
		assert_eq(req.result.ok, true)
		assert_not_nil(req.result.value.lease)
		assert_true(req.result.value.lease:release('not used'))
		h.admission_tx:close('done')
		h.session_tx:close('done')
		local done = recv_with_timeout(h.done_rx, 'manager done')
		assert_eq(done.snapshot.active, nil)
		assert_eq(done.snapshot.stats.released, 1)
	end)
end

function tests.test_real_sender_attempt_uses_session_bound_outbound_gate()
	fibers.run(function (scope)
		local h = start_manager(scope, { chunk_size = 3 })
		local c = ctx()
		h.outbound:bind(c)
		assert_true(h.session_tx:send(peer_session_event()))

		local req = slot_request('req-send')
		assert_true(h.admission_tx:send(req))
		local deadline = fibers.now() + 0.1
		while req.result == nil and fibers.now() < deadline do fibers.perform(sleep.sleep_op(0.001)) end
		local lease = req.result.value.lease
		assert_not_nil(lease)

		local source_owner = resource.owned(blob.from_string('abcdef'))
		local attempt, err = transfer.start_attempt(scope, lease, {
			request_id = 'req-send',
			request_generation = 1,
			source_owner = source_owner,
			target = 'updater/main',
			xfer_id = 'xfer-1',
			size = 6,
			digest_alg = protocol.DIGEST_ALG,
			digest = protocol.digest_hex('abcdef'),
		})
		assert_not_nil(attempt, err)

		local begin = recv_with_timeout(h.control_rx, 'xfer begin').frame
		assert_eq(begin.type, 'xfer_begin')
		assert_eq(begin.target, 'updater/main')

		assert_true(h.session_tx:send(transfer_frame_event(assert(protocol.xfer_ready('xfer-1')))))
		assert_true(h.session_tx:send(transfer_frame_event(assert(protocol.xfer_need('xfer-1', 0)))))
		local chunk1 = recv_with_timeout(h.bulk_rx, 'chunk 1').frame
		assert_eq(chunk1.type, 'xfer_chunk')
		assert_eq(chunk1.offset, 0)
		assert_eq(chunk1.data, 'abc')

		assert_true(h.session_tx:send(transfer_frame_event(assert(protocol.xfer_need('xfer-1', 3)))))
		local chunk2 = recv_with_timeout(h.bulk_rx, 'chunk 2').frame
		assert_eq(chunk2.offset, 3)
		assert_eq(chunk2.data, 'def')

		-- The receiver acknowledges the final accepted chunk with next == size.
		-- The sender must wait for this before sending xfer_commit so that
		-- control commit cannot overtake the final bulk frame.
		assert_true(h.session_tx:send(transfer_frame_event(assert(protocol.xfer_need('xfer-1', 6)))))
		local commit = recv_with_timeout(h.control_rx, 'commit').frame
		assert_eq(commit.type, 'xfer_commit')
		assert_true(h.session_tx:send(transfer_frame_event(assert(protocol.xfer_done('xfer-1')))))

		local ev = recv_with_timeout({ recv_op = function () return attempt:outcome_op() end }, 'attempt outcome')
		assert_eq(ev.status, 'ok')
		assert_eq(ev.result.sent_bytes, 6)

		h.admission_tx:close('done')
		h.session_tx:close('done')
		recv_with_timeout(h.done_rx, 'manager done')
	end)
end

function tests.test_session_drop_poisoned_lease_cannot_start_attempt()
	fibers.run(function (scope)
		local h = start_manager(scope)
		local c = ctx()
		h.outbound:bind(c)
		assert_true(h.session_tx:send(peer_session_event()))
		local req = slot_request('req-drop')
		assert_true(h.admission_tx:send(req))
		local deadline = fibers.now() + 0.1
		while req.result == nil and fibers.now() < deadline do fibers.perform(sleep.sleep_op(0.001)) end
		local lease = req.result.value.lease
		assert_true(h.session_tx:send({ kind = 'peer_session_dropped', session = c, reason = 'drop' }))
		fibers.perform(sleep.sleep_op(0.01))
		local h2, err = transfer.start_attempt(scope, lease, {})
		assert_nil(h2)
		assert_not_nil(err)
		h.admission_tx:close('done')
		h.session_tx:close('done')
		recv_with_timeout(h.done_rx, 'manager done')
	end)
end

function tests.test_manager_receives_inbound_transfer_for_registered_target()
	fibers.run(function (scope)
		local received = {}
		local committed = false
		local target = {}
		function target.open_sink_op(_, req)
			assert_eq(req.target, 'updater/main')
			assert_eq(req.size, 6)
			local sink = {}
			function sink.append_op(_, chunk)
				received[#received + 1] = chunk
				return fibers.always(true, nil)
			end
			function sink.commit_op(_, req2)
				committed = true
				assert_eq(req2.digest, protocol.digest_hex('abcdef'))
				return fibers.always({ staged = true }, nil)
			end
			function sink.abort(_) return true, nil end
			return fibers.always(sink, nil)
		end

		local h = start_manager(scope, {
			chunk_size = 3,
			receive_targets = { ['updater/main'] = target },
		})
		local c = ctx()
		h.outbound:bind(c)
		assert_true(h.session_tx:send(peer_session_event()))

		assert_true(h.session_tx:send(transfer_frame_event(assert(protocol.xfer_begin(
			'xfer-in-1', 'updater/main', 6, protocol.DIGEST_ALG, protocol.digest_hex('abcdef'),
			{ kind = 'firmware', component = 'mcu' }
		)))))

		local ready = recv_with_timeout(h.control_rx, 'receive ready').frame
		assert_eq(ready.type, 'xfer_ready')
		assert_eq(ready.xfer_id, 'xfer-in-1')

		local need0 = recv_with_timeout(h.control_rx, 'receive need 0').frame
		assert_eq(need0.type, 'xfer_need')
		assert_eq(need0.next, 0)

		assert_true(h.session_tx:send(transfer_frame_event(assert(protocol.xfer_chunk(
			'xfer-in-1', 0, 'abc', protocol.chunk_digest('abc')
		)))))
		local need3 = recv_with_timeout(h.control_rx, 'receive need 3').frame
		assert_eq(need3.type, 'xfer_need')
		assert_eq(need3.next, 3)

		assert_true(h.session_tx:send(transfer_frame_event(assert(protocol.xfer_chunk(
			'xfer-in-1', 3, 'def', protocol.chunk_digest('def')
		)))))
		local need6 = recv_with_timeout(h.control_rx, 'receive need 6').frame
		assert_eq(need6.type, 'xfer_need')
		assert_eq(need6.next, 6)

		assert_true(h.session_tx:send(transfer_frame_event(assert(protocol.xfer_commit(
			'xfer-in-1', 6, protocol.DIGEST_ALG, protocol.digest_hex('abcdef')
		)))))

		local done = recv_with_timeout(h.control_rx, 'receive done').frame
		assert_eq(done.type, 'xfer_done')
		assert_eq(table.concat(received), 'abcdef')
		assert_true(committed)

		local completed = wait_transfer_last_status(h, 'ok', 'inbound receive')
		assert_eq(completed.last.result.received_bytes, 6)

		h.admission_tx:close('done')
		h.session_tx:close('done')
		local result = recv_with_timeout(h.done_rx, 'manager done')
		assert_eq(result.snapshot.last.status, 'ok')
		assert_eq(result.snapshot.last.result.received_bytes, 6)
	end)
end

function tests.test_manager_reacks_stale_inbound_chunk_without_rewriting()
	fibers.run(function (scope)
		local received = {}
		local target = {}
		function target.open_sink_op(_, req)
			assert_eq(req.target, 'updater/main')
			local sink = {}
			function sink.append_op(_, chunk)
				received[#received + 1] = chunk
				return fibers.always(true, nil)
			end
			function sink.commit_op(_)
				return fibers.always({ staged = true }, nil)
			end
			function sink.abort(_) return true, nil end
			return fibers.always(sink, nil)
		end

		local h = start_manager(scope, {
			chunk_size = 3,
			receive_targets = { ['updater/main'] = target },
		})
		local c = ctx()
		h.outbound:bind(c)
		assert_true(h.session_tx:send(peer_session_event()))

		assert_true(h.session_tx:send(transfer_frame_event(assert(protocol.xfer_begin(
			'xfer-in-stale', 'updater/main', 6, protocol.DIGEST_ALG, protocol.digest_hex('abcdef'), nil
		)))))

		assert_eq(recv_with_timeout(h.control_rx, 'ready').frame.type, 'xfer_ready')
		assert_eq(recv_with_timeout(h.control_rx, 'need 0').frame.next, 0)

		assert_true(h.session_tx:send(transfer_frame_event(assert(protocol.xfer_chunk(
			'xfer-in-stale', 0, 'abc', protocol.chunk_digest('abc')
		)))))
		assert_eq(recv_with_timeout(h.control_rx, 'need 3').frame.next, 3)

		assert_true(h.session_tx:send(transfer_frame_event(assert(protocol.xfer_chunk(
			'xfer-in-stale', 0, 'abc', protocol.chunk_digest('abc')
		)))))
		assert_eq(recv_with_timeout(h.control_rx, 'stale need 3').frame.next, 3)
		assert_eq(#received, 1)

		assert_true(h.session_tx:send(transfer_frame_event(assert(protocol.xfer_chunk(
			'xfer-in-stale', 3, 'def', protocol.chunk_digest('def')
		)))))
		assert_eq(recv_with_timeout(h.control_rx, 'need 6').frame.next, 6)

		assert_true(h.session_tx:send(transfer_frame_event(assert(protocol.xfer_commit(
			'xfer-in-stale', 6, protocol.DIGEST_ALG, protocol.digest_hex('abcdef')
		)))))
		assert_eq(recv_with_timeout(h.control_rx, 'done').frame.type, 'xfer_done')
		assert_eq(table.concat(received), 'abcdef')

		h.admission_tx:close('done')
		h.session_tx:close('done')
		recv_with_timeout(h.done_rx, 'manager done')
	end)
end

function tests.test_manager_reasks_current_offset_for_future_inbound_chunk_and_completes()
	fibers.run(function (scope)
		local received = {}
		local target = {}
		function target.open_sink_op(_, req)
			assert_eq(req.target, 'updater/main')
			local sink = {}
			function sink.append_op(_, chunk)
				received[#received + 1] = chunk
				return fibers.always(true, nil)
			end
			function sink.commit_op(_)
				return fibers.always({ staged = true }, nil)
			end
			function sink.abort(_) return true, nil end
			return fibers.always(sink, nil)
		end

		local h = start_manager(scope, {
			chunk_size = 3,
			receive_targets = { ['updater/main'] = target },
		})
		local c = ctx()
		h.outbound:bind(c)
		assert_true(h.session_tx:send(peer_session_event()))

		assert_true(h.session_tx:send(transfer_frame_event(assert(protocol.xfer_begin(
			'xfer-in-future', 'updater/main', 6, protocol.DIGEST_ALG, protocol.digest_hex('abcdef'), nil
		)))))

		assert_eq(recv_with_timeout(h.control_rx, 'ready').frame.type, 'xfer_ready')
		assert_eq(recv_with_timeout(h.control_rx, 'need 0').frame.next, 0)

		assert_true(h.session_tx:send(transfer_frame_event(assert(protocol.xfer_chunk(
			'xfer-in-future', 3, 'def', protocol.chunk_digest('def')
		)))))
		assert_eq(recv_with_timeout(h.control_rx, 'future need 0').frame.next, 0)
		assert_eq(#received, 0)

		assert_true(h.session_tx:send(transfer_frame_event(assert(protocol.xfer_chunk(
			'xfer-in-future', 0, 'abc', protocol.chunk_digest('abc')
		)))))
		assert_eq(recv_with_timeout(h.control_rx, 'need 3').frame.next, 3)

		assert_true(h.session_tx:send(transfer_frame_event(assert(protocol.xfer_chunk(
			'xfer-in-future', 3, 'def', protocol.chunk_digest('def')
		)))))
		assert_eq(recv_with_timeout(h.control_rx, 'need 6').frame.next, 6)

		assert_true(h.session_tx:send(transfer_frame_event(assert(protocol.xfer_commit(
			'xfer-in-future', 6, protocol.DIGEST_ALG, protocol.digest_hex('abcdef')
		)))))
		assert_eq(recv_with_timeout(h.control_rx, 'done').frame.type, 'xfer_done')
		assert_eq(table.concat(received), 'abcdef')

		h.admission_tx:close('done')
		h.session_tx:close('done')
		recv_with_timeout(h.done_rx, 'manager done')
	end)
end

function tests.test_manager_reasks_same_offset_after_bad_chunk_digest_and_accepts_retry()
	fibers.run(function (scope)
		local received = {}
		local target = {}
		function target.open_sink_op(_, req)
			assert_eq(req.target, 'updater/main')
			local sink = {}
			function sink.append_op(_, chunk)
				received[#received + 1] = chunk
				return fibers.always(true, nil)
			end
			function sink.commit_op(_)
				return fibers.always({ staged = true }, nil)
			end
			function sink.abort(_) return true, nil end
			return fibers.always(sink, nil)
		end

		local h = start_manager(scope, {
			chunk_size = 3,
			retry_limit = 1,
			receive_targets = { ['updater/main'] = target },
		})
		local c = ctx()
		h.outbound:bind(c)
		assert_true(h.session_tx:send(peer_session_event()))

		assert_true(h.session_tx:send(transfer_frame_event(assert(protocol.xfer_begin(
			'xfer-in-retry', 'updater/main', 3, protocol.DIGEST_ALG, protocol.digest_hex('abc'), nil
		)))))

		assert_eq(recv_with_timeout(h.control_rx, 'ready').frame.type, 'xfer_ready')
		local need0 = recv_with_timeout(h.control_rx, 'need 0').frame
		assert_eq(need0.type, 'xfer_need')
		assert_eq(need0.next, 0)

		-- A bad digest for the expected offset should not advance the sink.
		assert_true(h.session_tx:send(transfer_frame_event({
			type = 'xfer_chunk',
			xfer_id = 'xfer-in-retry',
			offset = 0,
			data = 'abc',
			chunk_digest = '00000000',
		})))
		local retry_need = recv_with_timeout(h.control_rx, 'retry need 0').frame
		assert_eq(retry_need.type, 'xfer_need')
		assert_eq(retry_need.next, 0)
		assert_eq(#received, 0)

		assert_true(h.session_tx:send(transfer_frame_event(assert(protocol.xfer_chunk(
			'xfer-in-retry', 0, 'abc', protocol.chunk_digest('abc')
		)))))
		local need3 = recv_with_timeout(h.control_rx, 'need 3').frame
		assert_eq(need3.type, 'xfer_need')
		assert_eq(need3.next, 3)

		assert_true(h.session_tx:send(transfer_frame_event(assert(protocol.xfer_commit(
			'xfer-in-retry', 3, protocol.DIGEST_ALG, protocol.digest_hex('abc')
		)))))
		local done = recv_with_timeout(h.control_rx, 'done').frame
		assert_eq(done.type, 'xfer_done')
		assert_eq(table.concat(received), 'abc')

		local completed = wait_transfer_last_status(h, 'ok', 'inbound retry')
		assert_eq(completed.last.result.chunk_retries, 1)

		h.admission_tx:close('done')
		h.session_tx:close('done')
		recv_with_timeout(h.done_rx, 'manager done')
	end)
end

function tests.test_manager_aborts_inbound_transfer_for_unknown_target()
	fibers.run(function (scope)
		local h = start_manager(scope)
		local c = ctx()
		h.outbound:bind(c)
		assert_true(h.session_tx:send(peer_session_event()))
		assert_true(h.session_tx:send(transfer_frame_event(assert(protocol.xfer_begin(
			'xfer-unknown', 'updater/main', 0, protocol.DIGEST_ALG, protocol.digest_hex(''), nil
		)))))
		local abort = recv_with_timeout(h.control_rx, 'unsupported target abort').frame
		assert_eq(abort.type, 'xfer_abort')
		assert_eq(abort.xfer_id, 'xfer-unknown')
		assert_eq(abort.err, 'unsupported_target')
		h.admission_tx:close('done')
		h.session_tx:close('done')
		recv_with_timeout(h.done_rx, 'manager done')
	end)
end

return tests
