local busmod     = require 'bus'
local mailbox    = require 'fibers.mailbox'
local runfibers  = require 'tests.support.run_fibers'
local probe      = require 'tests.support.bus_probe'
local fakes      = require 'tests.support.fabric_fakes'

local session_ctl = require 'services.fabric.session_ctl'
local rpc_bridge  = require 'services.fabric.rpc_bridge'

local T = {}

local function new_bridge_env(bus, opts)
	opts = opts or {}
	local root_conn = bus:connect({ principal = opts.principal or 'bridge' })
	local state_conn = root_conn:derive()
	local session = session_ctl.new_state(opts.link_id or 'link-rpc', state_conn)
	local peer_conn = root_conn:derive({
		origin_factory = function ()
			local snap = session:get()
			return {
				kind = 'fabric_import',
				link_id = opts.link_id or 'link-rpc',
				peer_node = snap.peer_node,
				peer_sid = snap.peer_sid,
				generation = snap.generation,
			}
		end,
	})
	local rpc_tx, rpc_rx = mailbox.new(64, { full = 'reject_newest' })
	local tx_rpc_tx, tx_rpc_rx = mailbox.new(128, { full = 'reject_newest' })
	local status_tx, status_rx = mailbox.new(64, { full = 'reject_newest' })
	local helper_done_tx, helper_done_rx = mailbox.new(64, { full = 'reject_newest' })
	return {
		root_conn = root_conn,
		state_conn = state_conn,
		session = session,
		peer_conn = peer_conn,
		rpc_tx = rpc_tx,
		rpc_rx = rpc_rx,
		tx_rpc_tx = tx_rpc_tx,
		tx_rpc_rx = tx_rpc_rx,
		status_tx = status_tx,
		status_rx = status_rx,
		helper_done_tx = helper_done_tx,
		helper_done_rx = helper_done_rx,
	}
end

local function recv_frame(rx)
	local item, err = rx:recv()
	assert(item ~= nil, tostring(err))
	return item.frame or item
end

local function new_stub_svc()
	return {
		obs_log = function() end,
	}
end


local function wait_rpc_ready(env)
	local st, err = env.status_rx:recv()
	assert(st ~= nil, tostring(err))
	assert(st.kind == 'rpc_ready')
	return st
end

function T.export_publish_maps_local_topics_and_suppresses_same_link_imports()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local env = new_bridge_env(bus, { link_id = 'link-a' })
		local local_pub = bus:connect({ principal = 'localpub' })

		local ok, err = scope:spawn(function ()
			rpc_bridge.run({
				link_id = 'link-a',
				svc = new_stub_svc(),
				conn = env.peer_conn,
				session = env.session,
				rpc_rx = env.rpc_rx,
				tx_rpc = env.tx_rpc_tx,
				status_tx = env.status_tx,
				helper_done_rx = env.helper_done_rx,
				helper_done_tx = env.helper_done_tx,
				export_publish_rules = {
					{ ['local'] = { 'local' }, ['remote'] = { 'remote' } },
				},
			})
		end)
		assert(ok, tostring(err))
		wait_rpc_ready(env)

		local_pub:publish({ 'local', 'wifi' }, { up = true })
		env.peer_conn:publish({ 'local', 'loop' }, { reflected = true })

		local frame = recv_frame(env.tx_rpc_rx)
		assert(frame.type == 'pub')
		assert(frame.topic[1] == 'remote' and frame.topic[2] == 'wifi')
		assert(frame.payload.up == true)

		local none, nerr = fakes.recv_mailbox(env.tx_rpc_rx, 0.05)
		assert(none == nil)
		assert(tostring(nerr):match('timeout'))
	end)
end

function T.imported_pub_retain_and_unretain_are_applied_with_fabric_origin()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local env = new_bridge_env(bus, { link_id = 'link-b' })
		local observer = bus:connect()
		local sub = observer:subscribe({ 'seen', '#' })
		local rw = observer:watch_retained({ 'seen', '#' }, { replay = false, queue_len = 8 })

		env.session:update(function (s)
			s.peer_sid = 'peer-b'
			s.peer_node = 'peer-node'
			s.established = true
			s.ready = true
			s.state = 'ready'
		end, { bump_pulse = true })

		local ok, err = scope:spawn(function ()
			rpc_bridge.run({
				link_id = 'link-b',
				svc = new_stub_svc(),
				conn = env.peer_conn,
				session = env.session,
				rpc_rx = env.rpc_rx,
				tx_rpc = env.tx_rpc_tx,
				status_tx = env.status_tx,
				helper_done_rx = env.helper_done_rx,
				helper_done_tx = env.helper_done_tx,
				import_rules = {
					{ ['local'] = { 'seen' }, ['remote'] = { 'remote' } },
				},
			})
		end)
		assert(ok, tostring(err))

		env.rpc_tx:send({ msg = { type = 'pub', topic = { 'remote', 'wifi' }, payload = { up = true }, retain = false } })
		local msg = assert(select(1, sub:recv()))
		assert(msg.topic[1] == 'seen' and msg.topic[2] == 'wifi')
		assert(msg.origin.kind == 'fabric_import')
		assert(msg.origin.link_id == 'link-b')
		assert(msg.origin.peer_sid == 'peer-b')

		env.rpc_tx:send({ msg = { type = 'pub', topic = { 'remote', 'cfg' }, payload = { v = 1 }, retain = true } })
		local ev1 = assert(select(1, rw:recv()))
		assert(ev1.op == 'retain')
		assert(ev1.topic[1] == 'seen' and ev1.topic[2] == 'cfg')
		assert(ev1.origin.kind == 'fabric_import')

		env.rpc_tx:send({ msg = { type = 'unretain', topic = { 'remote', 'cfg' } } })
		local ev2 = assert(select(1, rw:recv()))
		assert(ev2.op == 'unretain')
		assert(ev2.topic[1] == 'seen' and ev2.topic[2] == 'cfg')
		assert(ev2.origin.kind == 'fabric_import')
	end)
end

function T.outbound_local_call_times_out_when_remote_reply_does_not_arrive()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local env = new_bridge_env(bus, { link_id = 'link-c' })
		local caller = bus:connect()

		env.session:update(function (s)
			s.established = true
			s.ready = true
			s.state = 'ready'
		end, { bump_pulse = true })

		local ok, err = scope:spawn(function ()
			rpc_bridge.run({
				link_id = 'link-c',
				svc = new_stub_svc(),
				conn = env.peer_conn,
				session = env.session,
				rpc_rx = env.rpc_rx,
				tx_rpc = env.tx_rpc_tx,
				status_tx = env.status_tx,
				helper_done_rx = env.helper_done_rx,
				helper_done_tx = env.helper_done_tx,
				outbound_call_rules = {
					{ ['local'] = { 'cmd', 'proxy', 'echo' }, ['remote'] = { 'remote', 'echo' }, timeout = 0.05 },
				},
			})
		end)
		assert(ok, tostring(err))
		local st = wait_rpc_ready(env)
		assert(st.ready == true)

		local reply, cerr = caller:call({ 'cmd', 'proxy', 'echo' }, { msg = 'hello' }, { timeout = 0.2 })
		assert(reply == nil)
		assert(tostring(cerr):match('timeout'))

		local frame = recv_frame(env.tx_rpc_rx)
		assert(frame.type == 'call')
		assert(frame.topic[1] == 'remote' and frame.topic[2] == 'echo')
	end)
end

function T.session_generation_change_fails_pending_outbound_calls()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local env = new_bridge_env(bus, { link_id = 'link-d' })
		local caller = bus:connect()
		local result, result_err

		env.session:update(function (s)
			s.established = true
			s.ready = true
			s.state = 'ready'
		end, { bump_pulse = true })

		local ok, err = scope:spawn(function ()
			rpc_bridge.run({
				link_id = 'link-d',
				svc = new_stub_svc(),
				conn = env.peer_conn,
				session = env.session,
				rpc_rx = env.rpc_rx,
				tx_rpc = env.tx_rpc_tx,
				status_tx = env.status_tx,
				helper_done_rx = env.helper_done_rx,
				helper_done_tx = env.helper_done_tx,
				outbound_call_rules = {
					{ ['local'] = { 'cmd', 'proxy', 'echo' }, ['remote'] = { 'remote', 'echo' }, timeout = 1.0 },
				},
			})
		end)
		assert(ok, tostring(err))

		local ok2, err2 = scope:spawn(function ()
			result, result_err = caller:call({ 'cmd', 'proxy', 'echo' }, { msg = 'hello' }, { timeout = 1.0 })
		end)
		assert(ok2, tostring(err2))

		local frame = recv_frame(env.tx_rpc_rx)
		assert(frame.type == 'call')
		env.session:update(function (s)
			s.generation = s.generation + 1
		end, { bump_pulse = true })

		assert(probe.wait_until(function ()
			return result == nil and tostring(result_err):match('session_reset') ~= nil
		end, { timeout = 0.5, interval = 0.01 }))
	end)
end

function T.inbound_remote_call_uses_helper_and_replies_successfully()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local env = new_bridge_env(bus, { link_id = 'link-e' })
		local svc_conn = bus:connect()
		local ep = svc_conn:bind({ 'svc', 'echo' }, { queue_len = 8 })

		local ok0, err0 = scope:spawn(function ()
			while true do
				local req, rerr = ep:recv()
				if not req then return end
				req:reply({ echoed = req.payload })
			end
		end)
		assert(ok0, tostring(err0))

		local ok, err = scope:spawn(function ()
			rpc_bridge.run({
				link_id = 'link-e',
				svc = new_stub_svc(),
				conn = env.peer_conn,
				session = env.session,
				rpc_rx = env.rpc_rx,
				tx_rpc = env.tx_rpc_tx,
				status_tx = env.status_tx,
				helper_done_rx = env.helper_done_rx,
				helper_done_tx = env.helper_done_tx,
				inbound_call_rules = {
					{ ['local'] = { 'svc', 'echo' }, ['remote'] = { 'remote', 'echo' }, timeout = 0.25 },
				},
			})
		end)
		assert(ok, tostring(err))

		env.rpc_tx:send({ msg = { type = 'call', id = 'req-1', topic = { 'remote', 'echo' }, payload = { msg = 'hi' } } })
		local frame = recv_frame(env.tx_rpc_rx)
		assert(frame.type == 'reply')
		assert(frame.id == 'req-1')
		assert(frame.ok == true)
		assert(type(frame.value) == 'table')
		assert(frame.value.echoed.msg == 'hi')
	end)
end

function T.inbound_remote_call_respects_helper_limit()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local env = new_bridge_env(bus, { link_id = 'link-f' })

		local ok, err = scope:spawn(function ()
			rpc_bridge.run({
				link_id = 'link-f',
				svc = new_stub_svc(),
				conn = env.peer_conn,
				session = env.session,
				rpc_rx = env.rpc_rx,
				tx_rpc = env.tx_rpc_tx,
				status_tx = env.status_tx,
				helper_done_rx = env.helper_done_rx,
				helper_done_tx = env.helper_done_tx,
				inbound_call_rules = {
					{ ['local'] = { 'svc', 'echo' }, ['remote'] = { 'remote', 'echo' }, timeout = 0.25 },
				},
				max_inbound_helpers = 0,
			})
		end)
		assert(ok, tostring(err))

		env.rpc_tx:send({ msg = { type = 'call', id = 'req-busy', topic = { 'remote', 'echo' }, payload = { msg = 'hi' } } })
		local frame = recv_frame(env.tx_rpc_rx)
		assert(frame.type == 'reply')
		assert(frame.id == 'req-busy')
		assert(frame.ok == false)
		assert(tostring(frame.err):match('busy'))
	end)
end

return T
