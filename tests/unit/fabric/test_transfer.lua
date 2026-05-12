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
		transfer_quiet = opts.transfer_quiet,
		log = opts.log,
		link_id = 'link-a',
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
			log = opts.log,
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
		target = 'updater/main',
		size = 12,
	})
	assert_eq(accepted, true)
	local snap = transfer.snapshot(state)
	assert_eq(snap.active.session.peer_sid, 'sid-1')
	assert_eq(snap.active.xfer_id, 'xfer-1')
	assert_eq(snap.active.target, 'updater/main')
	assert_eq(snap.active.size, 12)
	assert_eq(snap.active.sent, 0)
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
		local h = start_manager(scope, {
			chunk_size = 3,
			transfer_quiet = {},
		})
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

return tests
