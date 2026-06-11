-- tests/unit/fabric/test_session.lua
--
-- Focused tests for fabric.session as the sole promoter of raw wire frames into
-- session-context-tagged semantic events.

local fibers  = require 'fibers'
local sleep   = require 'fibers.sleep'
local mailbox = require 'fibers.mailbox'

local session  = require 'services.fabric.session'
local protocol = require 'services.fabric.protocol'
local queue    = require 'devicecode.support.queue'

local tests = {}

local function fail(msg)
	error(msg or 'assertion failed', 2)
end

local function assert_true(v, msg)
	if v ~= true then fail(msg or ('expected true, got ' .. tostring(v))) end
end

local function assert_nil(v, msg)
	if v ~= nil then fail(msg or ('expected nil, got ' .. tostring(v))) end
end

local function assert_not_nil(v, msg)
	if v == nil then fail(msg or 'expected non-nil value') end
end

local function assert_eq(a, b, msg)
	if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end
end

local function recv_with_timeout(rx, label, timeout)
	timeout = timeout or 0.25
	local which, item = fibers.perform(fibers.named_choice{
		item = rx:recv_op(),
		timeout = sleep.sleep_op(timeout),
	})
	if which == 'timeout' then
		fail('timed out waiting for ' .. tostring(label or 'item'))
	end
	return item
end

local function expect_no_item(rx, label, timeout)
	timeout = timeout or 0.05
	fibers.perform(sleep.sleep_op(timeout))
	local item = queue.try_recv_now(rx)
	assert_nil(item, label or 'expected no queued item')
end

local function start_session(scope, opts)
	opts = opts or {}
	local frame_tx, frame_rx = mailbox.new(16, { full = 'reject_newest' })
	local control_tx, control_rx = mailbox.new(16, { full = 'reject_newest' })
	local rpc_tx, rpc_rx = mailbox.new(16, { full = 'reject_newest' })
	local transfer_tx, transfer_rx = mailbox.new(16, { full = 'reject_newest' })
	local outbound = session.new_outbound_gate { tx_control = control_tx, tx_rpc = control_tx, tx_bulk = control_tx }
	local done_tx, done_rx = mailbox.new(1, { full = 'reject_newest' })

	local ok, err = scope:spawn(function ()
		local result = session.run(scope, {
			link_id = opts.link_id or 'link-a',
			peer_id = opts.peer_id or 'mcu',
			local_node = opts.local_node or 'cm5',
			local_sid = opts.local_sid or 'cm5-sid',
			identity_claim = opts.identity_claim,
			auth_claim = opts.auth_claim,
			frame_rx = frame_rx,
			tx_control = control_tx,
			outbound = outbound,
			rpc_tx = rpc_tx,
			transfer_tx = transfer_tx,
			hello_interval_s = opts.hello_interval_s or 10,
			ping_interval_s = opts.ping_interval_s or 10,
			liveness_timeout_s = opts.liveness_timeout_s or 20,
			bad_frame_limit = opts.bad_frame_limit,
			bad_frame_window_s = opts.bad_frame_window_s,
		})
		queue.try_admit_required(done_tx, result, 'session_done')
	end)
	assert_true(ok, err)

	return {
		frame_tx = frame_tx,
		control_rx = control_rx,
		rpc_rx = rpc_rx,
		transfer_rx = transfer_rx,
		done_rx = done_rx,
	}
end

local function admit_frame(tx, frame)
	local ok, err = queue.try_admit_required(tx, {
		kind = 'frame_received',
		frame = frame,
	}, 'test_frame_admit_failed')
	assert_true(ok, err)
end

local function admit_wire_error(tx, err)
	local ok, admit_err = queue.try_admit_required(tx, {
		kind = 'wire_error',
		err = err or 'decode_failed: bad json',
		at = fibers.now(),
	}, 'test_wire_error_admit_failed')
	assert_true(ok, admit_err)
end

function tests.test_session_establishes_and_emits_lifecycle_to_both_lanes()
	fibers.run(function (scope)
		local h = start_session(scope, {
			identity_claim = { id = 'cm5' },
		})

		local hello = recv_with_timeout(h.control_rx, 'initial hello')
		assert_eq(hello.frame.type, 'hello')
		assert_eq(hello.frame.proto, protocol.PROTO)
		assert_eq(hello.frame.node, 'cm5')
		assert_eq(hello.frame.identity.id, 'cm5')

		admit_frame(h.frame_tx, assert(protocol.hello_ack('mcu-sid', 'mcu')))

		local rpc_ev = recv_with_timeout(h.rpc_rx, 'rpc peer session')
		local xfer_ev = recv_with_timeout(h.transfer_rx, 'transfer peer session')
		assert_eq(rpc_ev.kind, 'peer_session')
		assert_eq(xfer_ev.kind, 'peer_session')
		assert_eq(rpc_ev.session.session_generation, 1)
		assert_eq(rpc_ev.session.peer_sid, 'mcu-sid')
		assert_eq(rpc_ev.session.peer_node, 'mcu')
		assert_eq(rpc_ev.session.proto, protocol.PROTO)

		h.frame_tx:close('done')
		local done = recv_with_timeout(h.done_rx, 'session done')
		assert_eq(done.role, 'session')
		assert_eq(done.snapshot.session_generation, 1)
	end)
end

function tests.test_non_session_frames_are_dropped_until_session_is_established()
	fibers.run(function (scope)
		local h = start_session(scope)
		recv_with_timeout(h.control_rx, 'initial hello')

		admit_frame(h.frame_tx, assert(protocol.pub({ 'state', 'self' }, { ok = true }, true)))

		local ev = queue.try_recv_now(h.rpc_rx)
		assert_nil(ev, 'rpc frame should not be emitted before session establishment')

		admit_frame(h.frame_tx, assert(protocol.hello_ack('mcu-sid', 'mcu')))
		recv_with_timeout(h.rpc_rx, 'peer session')

		admit_frame(h.frame_tx, assert(protocol.pub({ 'state', 'self' }, { ok = true }, true)))
		local routed = recv_with_timeout(h.rpc_rx, 'session-tagged rpc frame')
		assert_eq(routed.kind, 'session_frame')
		assert_eq(routed.lane, 'rpc')
		assert_eq(routed.session.session_generation, 1)
		assert_eq(routed.session.peer_sid, 'mcu-sid')
		assert_eq(routed.frame.type, 'pub')

		h.frame_tx:close('done')
		recv_with_timeout(h.done_rx, 'session done')
	end)
end

function tests.test_transfer_frames_are_tagged_for_transfer_lane_only()
	fibers.run(function (scope)
		local h = start_session(scope)
		recv_with_timeout(h.control_rx, 'initial hello')
		admit_frame(h.frame_tx, assert(protocol.hello_ack('mcu-sid', 'mcu')))
		recv_with_timeout(h.rpc_rx, 'rpc peer session')
		recv_with_timeout(h.transfer_rx, 'transfer peer session')

		admit_frame(h.frame_tx, assert(protocol.xfer_ready('xfer-1')))
		local ev = recv_with_timeout(h.transfer_rx, 'transfer frame')
		assert_eq(ev.kind, 'session_frame')
		assert_eq(ev.lane, 'transfer')
		assert_eq(ev.session.session_generation, 1)
		assert_eq(ev.frame.type, 'xfer_ready')

		local rpc_ev = queue.try_recv_now(h.rpc_rx)
		assert_nil(rpc_ev, 'transfer frame should not be emitted to rpc lane')

		h.frame_tx:close('done')
		recv_with_timeout(h.done_rx, 'session done')
	end)
end

function tests.test_new_peer_sid_drops_old_generation_and_starts_next_generation()
	fibers.run(function (scope)
		local h = start_session(scope)
		recv_with_timeout(h.control_rx, 'initial hello')

		admit_frame(h.frame_tx, assert(protocol.hello_ack('sid-1', 'mcu')))
		local first = recv_with_timeout(h.rpc_rx, 'first peer session')
		assert_eq(first.kind, 'peer_session')
		assert_eq(first.session.session_generation, 1)

		admit_frame(h.frame_tx, assert(protocol.hello('sid-2', 'mcu')))
		local drop = recv_with_timeout(h.rpc_rx, 'drop old peer session')
		local next_ev = recv_with_timeout(h.rpc_rx, 'next peer session')

		assert_eq(drop.kind, 'peer_session_dropped')
		assert_eq(drop.session.session_generation, 1)
		assert_eq(drop.session.peer_sid, 'sid-1')
		assert_eq(drop.reason, 'peer_sid_changed')

		assert_eq(next_ev.kind, 'peer_session')
		assert_eq(next_ev.session.session_generation, 2)
		assert_eq(next_ev.session.peer_sid, 'sid-2')

		local ack = recv_with_timeout(h.control_rx, 'hello ack for new sid')
		assert_eq(ack.frame.type, 'hello_ack')

		h.frame_tx:close('done')
		recv_with_timeout(h.done_rx, 'session done')
	end)
end

function tests.test_session_ignores_self_echoed_hello_before_expected_peer()
	fibers.run(function (scope)
		local h = start_session(scope)

		local hello = recv_with_timeout(h.control_rx, 'initial hello')
		assert_eq(hello.frame.type, 'hello')
		assert_eq(hello.frame.sid, 'cm5-sid')
		assert_eq(hello.frame.node, 'cm5')

		admit_frame(h.frame_tx, assert(protocol.hello('cm5-sid', 'cm5')))
		expect_no_item(h.rpc_rx, 'self echo should not emit rpc peer session')
		expect_no_item(h.transfer_rx, 'self echo should not emit transfer peer session')
		expect_no_item(h.control_rx, 'self echo should not trigger hello_ack')

		admit_frame(h.frame_tx, assert(protocol.hello_ack('mcu-sid', 'mcu')))
		local rpc_ev = recv_with_timeout(h.rpc_rx, 'rpc peer session after real ack')
		local xfer_ev = recv_with_timeout(h.transfer_rx, 'transfer peer session after real ack')
		assert_eq(rpc_ev.kind, 'peer_session')
		assert_eq(xfer_ev.kind, 'peer_session')
		assert_eq(rpc_ev.session.peer_node, 'mcu')
		assert_eq(rpc_ev.session.peer_sid, 'mcu-sid')
		assert_eq(xfer_ev.session.peer_node, 'mcu')
		assert_eq(xfer_ev.session.peer_sid, 'mcu-sid')

		h.frame_tx:close('done')
		recv_with_timeout(h.done_rx, 'session done')
	end)
end

function tests.test_session_rejects_wrong_peer_handshake_before_expected_peer()
	fibers.run(function (scope)
		local h = start_session(scope, { peer_id = 'mcu' })
		recv_with_timeout(h.control_rx, 'initial hello')

		admit_frame(h.frame_tx, assert(protocol.hello_ack('wrong-sid', 'bigbox-cm5')))
		expect_no_item(h.rpc_rx, 'wrong peer ack should not emit rpc peer session')
		expect_no_item(h.transfer_rx, 'wrong peer ack should not emit transfer peer session')

		admit_frame(h.frame_tx, assert(protocol.hello('mcu-sid', 'mcu')))
		local rpc_ev = recv_with_timeout(h.rpc_rx, 'rpc peer session after real hello')
		local xfer_ev = recv_with_timeout(h.transfer_rx, 'transfer peer session after real hello')
		assert_eq(rpc_ev.kind, 'peer_session')
		assert_eq(xfer_ev.kind, 'peer_session')
		assert_eq(rpc_ev.session.peer_node, 'mcu')
		assert_eq(rpc_ev.session.peer_sid, 'mcu-sid')
		assert_eq(xfer_ev.session.peer_node, 'mcu')
		assert_eq(xfer_ev.session.peer_sid, 'mcu-sid')

		local ack = recv_with_timeout(h.control_rx, 'hello ack for real peer')
		assert_eq(ack.frame.type, 'hello_ack')

		h.frame_tx:close('done')
		recv_with_timeout(h.done_rx, 'session done')
	end)
end

function tests.test_wire_errors_below_limit_are_counted_without_dropping_session()
	fibers.run(function (scope)
		local h = start_session(scope, { bad_frame_limit = 3, bad_frame_window_s = 10 })
		recv_with_timeout(h.control_rx, 'initial hello')
		admit_frame(h.frame_tx, assert(protocol.hello_ack('mcu-sid', 'mcu')))
		recv_with_timeout(h.rpc_rx, 'peer session')
		recv_with_timeout(h.transfer_rx, 'transfer peer session')

		admit_wire_error(h.frame_tx, 'decode_failed: truncated line')
		local stale = queue.try_recv_now(h.rpc_rx)
		assert_nil(stale, 'single bad frame should not drop session')

		admit_frame(h.frame_tx, assert(protocol.pub({ 'state', 'self' }, { ok = true }, true)))
		local routed = recv_with_timeout(h.rpc_rx, 'rpc frame after tolerated bad frame')
		assert_eq(routed.kind, 'session_frame')
		assert_eq(routed.frame.type, 'pub')

		h.frame_tx:close('done')
		local done = recv_with_timeout(h.done_rx, 'session done')
		assert_eq(done.snapshot.wire_errors, 1)
		assert_eq(done.snapshot.last_wire_error, 'decode_failed: truncated line')
	end)
end

function tests.test_bad_frame_limit_drops_current_peer_session()
	fibers.run(function (scope)
		local h = start_session(scope, { bad_frame_limit = 2, bad_frame_window_s = 10 })
		recv_with_timeout(h.control_rx, 'initial hello')
		admit_frame(h.frame_tx, assert(protocol.hello_ack('mcu-sid', 'mcu')))
		recv_with_timeout(h.rpc_rx, 'peer session')
		recv_with_timeout(h.transfer_rx, 'transfer peer session')

		admit_wire_error(h.frame_tx, 'decode_failed: first')
		assert_nil(queue.try_recv_now(h.rpc_rx), 'first bad frame should be tolerated')
		admit_wire_error(h.frame_tx, 'decode_failed: second')

		local drop = recv_with_timeout(h.rpc_rx, 'peer session drop')
		assert_eq(drop.kind, 'peer_session_dropped')
		assert_eq(drop.reason, 'bad_frame_limit')
		assert_eq(drop.session.peer_sid, 'mcu-sid')

		admit_frame(h.frame_tx, assert(protocol.pub({ 'state', 'self' }, { ok = true }, true)))
		assert_nil(queue.try_recv_now(h.rpc_rx), 'rpc frame should be dropped after bad-frame session reset')

		h.frame_tx:close('done')
		recv_with_timeout(h.done_rx, 'session done')
	end)
end

function tests.test_outbound_gate_accepts_only_current_session_context()
	fibers.run(function ()
		local control_tx, control_rx = mailbox.new(4, { full = 'reject_newest' })
		local rpc_tx, rpc_rx = mailbox.new(4, { full = 'reject_newest' })
		local bulk_tx, bulk_rx = mailbox.new(4, { full = 'reject_newest' })
		local gate = session.new_outbound_gate {
			tx_control = control_tx,
			tx_rpc = rpc_tx,
			tx_bulk = bulk_tx,
		}

		local ctx = { session_generation = 1, peer_sid = 'sid-1' }
		local rpc_frame = assert(protocol.pub({ 'state', 'self' }, { ok = true }, true))
		local bulk_frame = assert(protocol.xfer_chunk('xfer-1', 0, 'abc', protocol.chunk_digest('abc')))

		local ok, err = gate:send_rpc_frame_now(ctx, rpc_frame, 'test_rpc_send')
		assert_nil(ok)
		assert_not_nil(err)

		gate:bind(ctx)

		ok, err = gate:send_rpc_frame_now(ctx, rpc_frame, 'test_rpc_send')
		assert_true(ok, err)
		local item = recv_with_timeout(rpc_rx, 'gated rpc frame')
		assert_eq(item.kind, 'send_frame')
		assert_eq(item.lane, 'rpc')
		assert_eq(item.frame.type, 'pub')
		assert_eq(item.session.session_generation, 1)
		assert_eq(item.session.peer_sid, 'sid-1')
		assert_nil(queue.try_recv_now(control_rx))
		assert_nil(queue.try_recv_now(bulk_rx))

		ok, err = gate:send_rpc_frame_now(ctx, bulk_frame, 'test_rpc_wrong_lane')
		assert_nil(ok)
		assert_not_nil(err)

		ok, err = gate:send_transfer_bulk_frame_now(ctx, bulk_frame, 'test_bulk_send')
		assert_true(ok, err)
		item = recv_with_timeout(bulk_rx, 'gated bulk frame')
		assert_eq(item.lane, 'bulk')
		assert_eq(item.frame.type, 'xfer_chunk')

		ok, err = gate:send_rpc_frame_now({ session_generation = 2, peer_sid = 'sid-1' }, rpc_frame, 'test_rpc_send')
		assert_nil(ok)
		assert_not_nil(err)

		gate:drop('session_dropped')
		ok, err = gate:send_rpc_frame_now(ctx, rpc_frame, 'test_rpc_send')
		assert_nil(ok)
		assert_not_nil(err)
	end)
end


function tests.test_session_context_deep_copies_identity_and_auth_claims()
	local identity = { id = 'peer', nested = { role = 'mcu' } }
	local auth = { scheme = 'reserved', nested = { proof = 'claim' } }
	local ctx = session.new_session_context({
		link_id = 'link-a',
		link_generation = 1,
		session_generation = 1,
		peer_sid = 'sid-1',
		identity_claim = identity,
		auth_claim = auth,
	})

	identity.nested.role = 'mutated'
	auth.nested.proof = 'mutated'
	assert_eq(ctx.identity_claim.nested.role, 'mcu')
	assert_eq(ctx.auth_claim.nested.proof, 'claim')

	local copy = session.copy_context(ctx)
	copy.identity_claim.nested.role = 'copy-mutated'
	copy.auth_claim.nested.proof = 'copy-mutated'
	assert_eq(ctx.identity_claim.nested.role, 'mcu')
	assert_eq(ctx.auth_claim.nested.proof, 'claim')
end

return tests
