-- tests/unit/fabric/test_bridge.lua
--
-- Contract tests for the callback-free Fabric RPC bridge and local bus adapter.

local fibers  = require 'fibers'
local sleep   = require 'fibers.sleep'
local mailbox = require 'fibers.mailbox'

local bridge      = require 'services.fabric.bridge'
local bus_adapter = require 'services.fabric.bus_adapter'
local session     = require 'services.fabric.session'
local protocol    = require 'services.fabric.protocol'
local queue       = require 'devicecode.support.queue'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_true(v, msg) if v ~= true then fail(msg or ('expected true, got ' .. tostring(v))) end end
local function assert_nil(v, msg) if v ~= nil then fail(msg or ('expected nil, got ' .. tostring(v))) end end
local function assert_not_nil(v, msg) if v == nil then fail(msg or 'expected non-nil value') end end
local function assert_eq(a, b, msg) if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end end

local function recv_with_timeout(rx, label, timeout)
	timeout = timeout or 0.25
	local which, item = fibers.perform(fibers.named_choice{
		item = rx:recv_op(),
		timeout = sleep.sleep_op(timeout),
	})
	if which == 'timeout' then fail('timed out waiting for ' .. tostring(label or 'item')) end
	return item
end

local function try_recv(rx)
	return queue.try_recv_now(rx)
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

local function peer_drop_event(gen, sid, reason)
	return { kind = 'peer_session_dropped', session = ctx(gen, sid), reason = reason or 'test_drop', at = fibers.now() }
end

local function rpc_event(frame, gen, sid)
	return { kind = 'session_frame', lane = 'rpc', session = ctx(gen, sid), frame = frame, at = fibers.now() }
end

local function fake_request()
	local r = { resolved = false }
	function r:reply(v) self.resolved = 'reply'; self.value = v; return true end
	function r:fail(e) self.resolved = 'fail'; self.err = e; return true end
	return r
end

local function start_bridge(scope, opts)
	opts = opts or {}
	local local_tx, local_rx = mailbox.new(32, { full = 'reject_newest' })
	local session_in_tx, session_in_rx = mailbox.new(32, { full = 'reject_newest' })
	local session_tx, session_rx = mailbox.new(32, { full = 'reject_newest' })
	local bus_tx, bus_rx = mailbox.new(32, { full = 'reject_newest' })
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
	local ok_forward, forward_err = scope:spawn(function ()
		while true do
			local ev = fibers.perform(session_in_rx:recv_op())
			if ev == nil then
				session_tx:close('test complete')
				return
			end
			if ev.kind == 'peer_session' then
				outbound:bind(ev.session)
			elseif ev.kind == 'peer_session_dropped' then
				outbound:drop(ev.reason or 'test_drop')
			end
			local ok, err = queue.try_admit_required(session_tx, ev, 'test_session_forward_failed')
			if ok ~= true then error(err or 'test_session_forward_failed', 0) end
		end
	end)
	assert_true(ok_forward, forward_err)

	local params = {
		link_id = 'link-a',
		link_generation = 1,
		local_rx = local_rx,
		session_rx = session_rx,
		outbound = outbound,
		bus_tx = bus_tx,
		state_tx = state_tx,
		import_rules = opts.import_rules or {
			{ remote_prefix = { 'state', 'self' }, local_prefix = { 'raw', 'member', 'mcu', 'state' } },
			{ remote_prefix = { 'event', 'self' }, local_prefix = { 'raw', 'member', 'mcu', 'event' } },
		},
		export_publish_rules = opts.export_publish_rules or {
			{ local_prefix = { 'local' }, remote_prefix = { 'remote' } },
		},
		export_retained_rules = opts.export_retained_rules or {
			{ local_prefix = { 'retained' }, remote_prefix = { 'remote_retained' } },
		},
		outbound_call_rules = opts.outbound_call_rules or {
			{ local_topic = { 'cap', 'test-local', 'main', 'rpc', 'echo' }, remote_topic = { 'cap', 'test-remote', 'main', 'rpc', 'echo' } },
		},
		inbound_call_rules = opts.inbound_call_rules or {
			{ remote_topic = { 'cap', 'test-remote', 'main', 'rpc', 'echo' }, local_topic = { 'cap', 'test-local', 'main', 'rpc', 'echo' } },
		},
		call_timeout_s = opts.call_timeout_s or 0.05,
	}

	local ok, err = scope:spawn(function ()
		local result = bridge.run(scope, params)
		queue.try_admit_required(done_tx, result, 'bridge_done')
	end)
	assert_true(ok, err)

	return {
		local_tx = local_tx,
		session_tx = session_in_tx,
		bus_rx = bus_rx,
		state_rx = state_rx,
		outbound = outbound,
		rpc_rx = outbound_rpc_rx,
		control_rx = outbound_control_rx,
		bulk_rx = outbound_bulk_rx,
		done_rx = done_rx,
	}
end

local function close_bridge(h)
	h.local_tx:close('test complete')
	h.session_tx:close('test complete')
	return recv_with_timeout(h.done_rx, 'bridge done')
end

function tests.test_local_publish_is_mapped_and_sent_through_session_gate()
	fibers.run(function (scope)
		local h = start_bridge(scope)
		assert_true(h.session_tx:send(peer_session_event()))
		local state = recv_with_timeout(h.state_rx, 'initial state')
		assert_eq(state.kind, 'component_snapshot')
		assert_true(h.local_tx:send({ kind = 'publish', topic = { 'local', 'a' }, payload = { v = 1 } }))
		local item = recv_with_timeout(h.rpc_rx, 'outbound pub')
		assert_eq(item.kind, 'send_frame')
		assert_eq(item.frame.type, 'pub')
		assert_eq(item.frame.topic[1], 'remote')
		assert_eq(item.frame.topic[2], 'a')
		assert_eq(item.session.peer_sid, 'sid-1')
		close_bridge(h)
	end)
end

function tests.test_remote_retained_publish_emits_bus_command_and_updates_import_count()
	fibers.run(function (scope)
		local h = start_bridge(scope)
		assert_true(h.session_tx:send(peer_session_event()))
		assert_true(h.session_tx:send(rpc_event(assert(protocol.pub({ 'state', 'self', 'software' }, { image_id = 'i1' }, true)))))
		local cmd = recv_with_timeout(h.bus_rx, 'retain command')
		assert_eq(cmd.kind, 'retain')
		assert_eq(cmd.topic[1], 'raw')
		assert_eq(cmd.topic[4], 'state')
		assert_eq(cmd.topic[5], 'software')
		assert_eq(cmd.session.peer_sid, 'sid-1')
		close_bridge(h)
	end)
end

function tests.test_peer_session_change_clears_imported_retained_state_by_bus_command()
	fibers.run(function (scope)
		local h = start_bridge(scope)
		assert_true(h.session_tx:send(peer_session_event(1, 'sid-1')))
		assert_true(h.session_tx:send(rpc_event(assert(protocol.pub({ 'state', 'self', 'updater' }, { state = 'ready' }, true)), 1, 'sid-1')))
		recv_with_timeout(h.bus_rx, 'retain command')
		assert_true(h.session_tx:send(peer_session_event(2, 'sid-2')))
		local cmd = recv_with_timeout(h.bus_rx, 'clear command')
		assert_eq(cmd.kind, 'unretain')
		assert_eq(cmd.topic[5], 'updater')
		close_bridge(h)
	end)
end

function tests.test_peer_session_drop_clears_imported_retained_state_by_bus_command()
	fibers.run(function (scope)
		local h = start_bridge(scope)
		assert_true(h.session_tx:send(peer_session_event(1, 'sid-1')))
		assert_true(h.session_tx:send(rpc_event(assert(protocol.pub({ 'state', 'self', 'software' }, { image_id = 'i1' }, true)), 1, 'sid-1')))
		recv_with_timeout(h.bus_rx, 'retain command')
		assert_true(h.session_tx:send(peer_drop_event(1, 'sid-1', 'bad_frame_limit')))
		local cmd = recv_with_timeout(h.bus_rx, 'clear command')
		assert_eq(cmd.kind, 'unretain')
		assert_eq(cmd.topic[5], 'software')
		assert_eq(cmd.session.peer_sid, 'sid-1')
		close_bridge(h)
	end)
end

function tests.test_stale_peer_drop_does_not_clear_current_imported_state()
	fibers.run(function (scope)
		local h = start_bridge(scope)
		assert_true(h.session_tx:send(peer_session_event(1, 'sid-1')))
		assert_true(h.session_tx:send(rpc_event(assert(protocol.pub({ 'state', 'self', 'software' }, { image_id = 'i1' }, true)), 1, 'sid-1')))
		recv_with_timeout(h.bus_rx, 'retain command')
		assert_true(h.session_tx:send(peer_session_event(2, 'sid-2')))
		recv_with_timeout(h.bus_rx, 'clear command')
		assert_true(h.session_tx:send(rpc_event(assert(protocol.pub({ 'state', 'self', 'software' }, { image_id = 'i2' }, true)), 2, 'sid-2')))
		recv_with_timeout(h.bus_rx, 'retain command 2')
		assert_true(h.session_tx:send(peer_drop_event(1, 'sid-1', 'old_drop')))
		local stale = try_recv(h.bus_rx)
		assert_nil(stale)
		close_bridge(h)
	end)
end

function tests.test_inbound_call_is_routed_to_bus_command_and_reply_frame_is_sent()
	fibers.run(function (scope)
		local h = start_bridge(scope)
		assert_true(h.session_tx:send(peer_session_event()))
		assert_true(h.session_tx:send(rpc_event(assert(protocol.call('call-1', { 'cap', 'test-remote', 'main', 'rpc', 'echo' }, { n = 1 })))))
		local cmd = recv_with_timeout(h.bus_rx, 'bus call command')
		assert_eq(cmd.kind, 'call')
		assert_eq(cmd.topic[1], 'cap')
		assert_eq(cmd.topic[2], 'test-local')
		assert_eq(cmd.topic[4], 'rpc')
		queue.try_admit_required(cmd.reply_tx, { ok = true, payload = { answer = 42 } }, 'call reply')
		local frame = recv_with_timeout(h.rpc_rx, 'reply frame').frame
		assert_eq(frame.type, 'reply')
		assert_eq(frame.id, 'call-1')
		assert_eq(frame.ok, true)
		assert_eq(frame.payload.answer, 42)
		close_bridge(h)
	end)
end

function tests.test_outbound_call_sends_call_frame_and_routes_remote_reply_to_request()
	fibers.run(function (scope)
		local h = start_bridge(scope)
		assert_true(h.session_tx:send(peer_session_event()))
		local req = fake_request()
		assert_true(h.local_tx:send({ kind = 'call', id = 'local-1', topic = { 'cap', 'test-local', 'main', 'rpc', 'echo' }, payload = { q = true }, request = req }))
		local frame = recv_with_timeout(h.rpc_rx, 'outbound call frame').frame
		assert_eq(frame.type, 'call')
		assert_eq(frame.id, 'local-1')
		assert_eq(frame.topic[1], 'cap')
		assert_eq(frame.topic[2], 'test-remote')
		assert_eq(frame.topic[4], 'rpc')
		assert_true(h.session_tx:send(rpc_event(assert(protocol.reply('local-1', true, { ok = 'yes' }, nil)))))
		local deadline = fibers.now() + 0.25
		while req.resolved == false and fibers.now() < deadline do fibers.perform(sleep.sleep_op(0.001)) end
		assert_eq(req.resolved, 'reply')
		assert_eq(req.value.payload.ok, 'yes')
		close_bridge(h)
	end)
end

function tests.test_bus_adapter_remote_commands_use_local_bus_methods()
	fibers.run(function (scope)
		local command_tx, command_rx = mailbox.new(8, { full = 'reject_newest' })
		local calls = {}
		local conn = {}
		function conn:publish(topic, payload, opts) calls[#calls + 1] = { kind = 'publish', topic = topic, payload = payload, opts = opts }; return true end
		function conn:retain(topic, payload, opts) calls[#calls + 1] = { kind = 'retain', topic = topic, payload = payload, opts = opts }; return true end
		function conn:unretain(topic, opts) calls[#calls + 1] = { kind = 'unretain', topic = topic, opts = opts }; return true end
		function conn:call_op(topic, payload, opts) calls[#calls + 1] = { kind = 'call', topic = topic, payload = payload, opts = opts }; return fibers.always({ ok = true }, nil) end

		local ok, err = scope:spawn(function ()
			-- Use the public runtime with no subscriptions and drive its command queue.
			local rt = bus_adapter.local_runtime(scope, conn, { link_id = 'link-a', link_generation = 1 })
			command_tx, command_rx = rt.command_tx, nil
			fibers.perform(sleep.sleep_op(0.03))
			rt:terminate('done')
		end)
		assert_true(ok, err)
		fibers.perform(sleep.sleep_op(0.001))
		assert_true(command_tx:send({ kind = 'retain', topic = { 'raw' }, payload = { v = 1 }, session = ctx(), origin_kind = 'remote_retain' }))
		local deadline = fibers.now() + 0.1
		while #calls == 0 and fibers.now() < deadline do fibers.perform(sleep.sleep_op(0.001)) end
		assert_eq(calls[1].kind, 'retain')
		assert_eq(calls[1].opts.extra.fabric.session.peer_sid, 'sid-1')
	end)
end


function tests.test_bridge_local_outbound_calls_propagate_bus_request_abandonment()
	local f = assert(io.open('../src/services/fabric/bridge.lua', 'r'))
	local src = f:read('*a'); f:close()
	if not src:find('cancel_op      = cancel_op', 1, true) then fail('bridge scoped work wrapper should accept cancel_op') end
	if not src:find('owner:caller_cancel_op()', 1, true) then fail('outbound local bus calls should pass caller_cancel_op') end
end

return tests
