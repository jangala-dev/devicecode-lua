local busmod    = require 'bus'
local mailbox   = require 'fibers.mailbox'
local runfibers = require 'tests.support.run_fibers'
local probe     = require 'tests.support.bus_probe'

local session_ctl = require 'services.fabric.session_ctl'

local T = {}

local function new_stub_svc()
	return {
		obs_log = function() end,
	}
end

local function new_ctx(bus, link_id)
	local state_conn = bus:connect()
	local control_tx, control_rx = mailbox.new(16, { full = 'reject_newest' })
	local tx_control_tx, tx_control_rx = mailbox.new(16, { full = 'reject_newest' })
	local status_tx, status_rx = mailbox.new(16, { full = 'reject_newest' })
	local session = session_ctl.new_state(link_id, state_conn)
	return {
		state_conn = state_conn,
		control_tx = control_tx,
		control_rx = control_rx,
		tx_control_tx = tx_control_tx,
		tx_control_rx = tx_control_rx,
		status_tx = status_tx,
		status_rx = status_rx,
		session = session,
	}
end

function T.handshake_and_status_readiness_drive_ready_state()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local observer = bus:connect()
		local ctx = new_ctx(bus, 'link-1')

		local ok, err = scope:spawn(function ()
			session_ctl.run({
				link_id = 'link-1',
				svc = new_stub_svc(),
				session = ctx.session,
				control_rx = ctx.control_rx,
				status_rx = ctx.status_rx,
				tx_control = ctx.tx_control_tx,
				state_conn = ctx.state_conn,
				node_id = 'node-a',
				hello_interval_s = 0.05,
				ping_interval_s = 0.5,
				liveness_timeout_s = 1.0,
			})
		end)
		assert(ok, tostring(err))

		assert(probe.wait_until(function ()
			return ctx.session:get().state == 'establishing'
		end, { timeout = 0.5, interval = 0.01 }))

		local hello_item = assert(select(1, ctx.tx_control_rx:recv()))
		assert(hello_item.frame.type == 'hello')
		assert(type(hello_item.frame.sid) == 'string')

		local before = ctx.session:get()
		ctx.control_tx:send({ msg = { type = 'hello', sid = 'peer-sid', node = 'peer-node' }, at = require('fibers').now() })
		local ack_item = assert(select(1, ctx.tx_control_rx:recv()))
		assert(ack_item.frame.type == 'hello_ack')

		ctx.status_tx:send({ kind = 'rpc_ready', ready = true })

		assert(probe.wait_until(function ()
			local snap = ctx.session:get()
			return snap.established == true and snap.ready == true and snap.state == 'ready'
		end, { timeout = 0.5, interval = 0.01 }))

		local snap = ctx.session:get()
		assert(snap.peer_sid == 'peer-sid')
		assert(snap.peer_node == 'peer-node')
		assert(snap.generation == before.generation)

		local retained = probe.wait_payload(observer, { 'state', 'fabric', 'link', 'link-1', 'session' }, { timeout = 0.25 })
		assert(retained.kind == 'fabric.link.session')
		assert(retained.component == 'session')
		assert(retained.link_id == 'link-1')
		assert(type(retained.status) == 'table')
		assert(retained.status.state == 'ready')
		assert(retained.status.ready == true)
		assert(retained.status.peer_sid == 'peer-sid')
	end)
end

function T.peer_session_change_bumps_generation_and_updates_snapshot()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local ctx = new_ctx(bus, 'link-2')

		local ok, err = scope:spawn(function ()
			session_ctl.run({
				link_id = 'link-2',
				svc = new_stub_svc(),
				session = ctx.session,
				control_rx = ctx.control_rx,
				status_rx = ctx.status_rx,
				tx_control = ctx.tx_control_tx,
				state_conn = ctx.state_conn,
				node_id = 'node-a',
				hello_interval_s = 0.05,
				ping_interval_s = 1.0,
				liveness_timeout_s = 1.0,
			})
		end)
		assert(ok, tostring(err))

		assert(select(1, ctx.tx_control_rx:recv()).frame.type == 'hello')
		ctx.control_tx:send({ msg = { type = 'hello', sid = 'peer-1', node = 'peer-a' }, at = require('fibers').now() })
		assert(select(1, ctx.tx_control_rx:recv()).frame.type == 'hello_ack')
		ctx.status_tx:send({ kind = 'rpc_ready', ready = true })
		assert(probe.wait_until(function () return ctx.session:get().ready == true end, { timeout = 0.5, interval = 0.01 }))

		local first = ctx.session:get()
		ctx.control_tx:send({ msg = { type = 'hello', sid = 'peer-2', node = 'peer-b' }, at = require('fibers').now() })
		assert(select(1, ctx.tx_control_rx:recv()).frame.type == 'hello_ack')

		assert(probe.wait_until(function ()
			local snap = ctx.session:get()
			return snap.peer_sid == 'peer-2' and snap.generation == first.generation + 1
		end, { timeout = 0.5, interval = 0.01 }))
	end)
end

function T.liveness_timeout_faults_the_link_controller()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local ctx = new_ctx(bus, 'link-3')
		local child, cerr = scope:child()
		assert(child ~= nil, tostring(cerr))

		local ok, err = child:spawn(function ()
			session_ctl.run({
				link_id = 'link-3',
				svc = new_stub_svc(),
				session = ctx.session,
				control_rx = ctx.control_rx,
				status_rx = ctx.status_rx,
				tx_control = ctx.tx_control_tx,
				state_conn = ctx.state_conn,
				node_id = 'node-a',
				hello_interval_s = 0.01,
				ping_interval_s = 0.01,
				liveness_timeout_s = 0.05,
			})
		end)
		assert(ok, tostring(err))

		assert(select(1, ctx.tx_control_rx:recv()).frame.type == 'hello')
		ctx.control_tx:send({ msg = { type = 'hello', sid = 'peer-live', node = 'peer-live' }, at = require('fibers').now() })
		assert(select(1, ctx.tx_control_rx:recv()).frame.type == 'hello_ack')
		ctx.status_tx:send({ kind = 'rpc_ready', ready = true })
		assert(probe.wait_until(function () return ctx.session:get().ready == true end, { timeout = 0.25, interval = 0.005 }))

		local st, rep, primary = require('fibers').perform(child:join_op())
		assert(st == 'failed', tostring(primary))
		assert(tostring(primary):match('peer_liveness_timeout') or tostring(primary):match('peer_pong_timeout'))
		assert(type(rep) == 'table')
	end, { timeout = 1.0 })
end

return T
