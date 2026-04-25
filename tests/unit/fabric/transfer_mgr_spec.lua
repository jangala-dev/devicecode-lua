local busmod      = require 'bus'
local mailbox     = require 'fibers.mailbox'
local runfibers   = require 'tests.support.run_fibers'
local probe       = require 'tests.support.bus_probe'

local protocol      = require 'services.fabric.protocol'
local session_ctl   = require 'services.fabric.session_ctl'
local transfer_mgr  = require 'services.fabric.transfer_mgr'
local checksum      = require 'shared.hash.xxhash32'

local T = {}

local function new_env(bus, link_id)
	local state_conn = bus:connect()
	local session = session_ctl.new_state(link_id, state_conn)
	local xfer_tx, xfer_rx = mailbox.new(64, { full = 'reject_newest' })
	local tx_control_tx, tx_control_rx = mailbox.new(64, { full = 'reject_newest' })
	local tx_bulk_tx, tx_bulk_rx = mailbox.new(64, { full = 'reject_newest' })
	local transfer_ctl_tx, transfer_ctl_rx = mailbox.new(16, { full = 'reject_newest' })
	local rpc_owner = bus:connect()
	local rpc_caller = bus:connect()
	local ep = rpc_owner:bind({ 'cmd', 'xfer', link_id }, { queue_len = 16 })
	return {
		conn = state_conn,
		session = session,
		xfer_tx = xfer_tx,
		xfer_rx = xfer_rx,
		tx_control_tx = tx_control_tx,
		tx_control_rx = tx_control_rx,
		tx_bulk_tx = tx_bulk_tx,
		tx_bulk_rx = tx_bulk_rx,
		transfer_ctl_tx = transfer_ctl_tx,
		transfer_ctl_rx = transfer_ctl_rx,
		rpc_owner = rpc_owner,
		rpc_caller = rpc_caller,
		ep = ep,
		topic = { 'cmd', 'xfer', link_id },
	}
end

local function recv_mailbox(rx)
	local item, err = rx:recv()
	assert(item ~= nil, tostring(err))
	return item
end

local function spawn_transfer_endpoint(scope, env)
	local ok, err = scope:spawn(function ()
		while true do
			local req, _rerr = env.ep:recv()
			if not req then return end
			local sok, sreason = env.transfer_ctl_tx:send(req)
			if sok ~= true then
				req:fail(sreason or 'queue_closed')
			end
		end
	end)
	assert(ok, tostring(err))
end

function T.outgoing_transfer_happy_path_emits_begin_chunk_commit_and_reply()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local env = new_env(bus, 'link-x1')
		local raw = 'hello world'

		spawn_transfer_endpoint(scope, env)

		local ok, err = scope:spawn(function ()
			transfer_mgr.run({
				link_id = 'link-x1',
				conn = env.conn,
				session = env.session,
				xfer_rx = env.xfer_rx,
				tx_control = env.tx_control_tx,
				tx_bulk = env.tx_bulk_tx,
				transfer_ctl_rx = env.transfer_ctl_rx,
				chunk_size = 32,
				transfer_phase_timeout_s = 0.5,
			})
		end)
		assert(ok, tostring(err))

		local reply, reply_err
		local okc, errc = scope:spawn(function ()
			reply, reply_err = env.rpc_caller:call(env.topic, {
				op = 'send_blob',
				link_id = 'link-x1',
				source = raw,
			}, { timeout = 1.0 })
		end)
		assert(okc, tostring(errc))

		local begin = recv_mailbox(env.tx_control_rx).frame
		assert(begin.type == 'xfer_begin')
		assert(begin.size == #raw)

		env.xfer_tx:send({ msg = { type = 'xfer_ready', xfer_id = begin.xfer_id } })
		local chunk = recv_mailbox(env.tx_bulk_rx).frame
		assert(chunk.type == 'xfer_chunk')
		assert(chunk.xfer_id == begin.xfer_id)
		assert(chunk.offset == 0)
		assert(chunk.data == protocol.encode_chunk_data(raw))

		env.xfer_tx:send({ msg = { type = 'xfer_need', xfer_id = begin.xfer_id, next = #raw } })
		local commit = recv_mailbox(env.tx_control_rx).frame
		assert(commit.type == 'xfer_commit')
		assert(commit.xfer_id == begin.xfer_id)
		assert(commit.size == #raw)

		env.xfer_tx:send({ msg = { type = 'xfer_done', xfer_id = begin.xfer_id } })
		assert(probe.wait_until(function () return reply ~= nil end, { timeout = 0.5, interval = 0.01 }))
		assert(reply_err == nil)
		assert(reply.ok == true)
		assert(reply.xfer_id == begin.xfer_id)
		assert(reply.size == #raw)
	end)
end

function T.incoming_transfer_happy_path_accepts_chunks_and_commits()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local observer = bus:connect()
		local env = new_env(bus, 'link-x2')
		local raw = 'payload'
		local digest = checksum.digest_hex(raw)

		local ok, err = scope:spawn(function ()
			transfer_mgr.run({
				link_id = 'link-x2',
				conn = env.conn,
				session = env.session,
				xfer_rx = env.xfer_rx,
				tx_control = env.tx_control_tx,
				tx_bulk = env.tx_bulk_tx,
				transfer_ctl_rx = env.transfer_ctl_rx,
				chunk_size = 32,
				transfer_phase_timeout_s = 0.5,
			})
		end)
		assert(ok, tostring(err))

		env.xfer_tx:send({
			msg = {
				type = 'xfer_begin',
				xfer_id = 'in-1',
				size = #raw,
				checksum = digest,
				meta = { name = 'blob' },
			}
		})
		local ready = recv_mailbox(env.tx_control_rx).frame
		assert(ready.type == 'xfer_ready')
		assert(ready.xfer_id == 'in-1')

		local chunk_frame = assert(protocol.make_xfer_chunk('in-1', 0, raw))
		env.xfer_tx:send({ msg = chunk_frame })
		local need = recv_mailbox(env.tx_control_rx).frame
		assert(need.type == 'xfer_need')
		assert(need.next == #raw)

		env.xfer_tx:send({
			msg = {
				type = 'xfer_commit',
				xfer_id = 'in-1',
				size = #raw,
				checksum = digest,
			}
		})
		local done = recv_mailbox(env.tx_control_rx).frame
		assert(done.type == 'xfer_done')
		assert(done.xfer_id == 'in-1')

		local retained = probe.wait_payload(observer, { 'state', 'fabric', 'link', 'link-x2', 'transfer' }, { timeout = 0.25 })
		assert(retained.kind == 'fabric.link.transfer')
		assert(retained.component == 'transfer')
		assert(retained.link_id == 'link-x2')
		assert(type(retained.status) == 'table')
		assert(retained.status.state == 'done')
		assert(retained.status.direction == 'in')
		assert(retained.status.xfer_id == 'in-1')
	end)
end

function T.session_generation_change_aborts_outgoing_transfer()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local env = new_env(bus, 'link-x3')

		spawn_transfer_endpoint(scope, env)

		local ok, err = scope:spawn(function ()
			transfer_mgr.run({
				link_id = 'link-x3',
				conn = env.conn,
				session = env.session,
				xfer_rx = env.xfer_rx,
				tx_control = env.tx_control_tx,
				tx_bulk = env.tx_bulk_tx,
				transfer_ctl_rx = env.transfer_ctl_rx,
				chunk_size = 4,
				transfer_phase_timeout_s = 1.0,
			})
		end)
		assert(ok, tostring(err))

		local reply, reply_err
		local okc, errc = scope:spawn(function ()
			reply, reply_err = env.rpc_caller:call(env.topic, {
				op = 'send_blob',
				link_id = 'link-x3',
				source = 'abcdefgh',
			}, { timeout = 1.0 })
		end)
		assert(okc, tostring(errc))

		local begin = recv_mailbox(env.tx_control_rx).frame
		assert(begin.type == 'xfer_begin')

		env.session:update(function (s)
			s.generation = s.generation + 1
		end, { bump_pulse = true })

		assert(probe.wait_until(function ()
			return reply == nil and tostring(reply_err):match('session_reset') ~= nil
		end, { timeout = 0.5, interval = 0.01 }))
	end)
end

function T.only_one_outgoing_transfer_is_admitted_at_a_time()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local env = new_env(bus, 'link-x4')

		spawn_transfer_endpoint(scope, env)

		local ok, err = scope:spawn(function ()
			transfer_mgr.run({
				link_id = 'link-x4',
				conn = env.conn,
				session = env.session,
				xfer_rx = env.xfer_rx,
				tx_control = env.tx_control_tx,
				tx_bulk = env.tx_bulk_tx,
				transfer_ctl_rx = env.transfer_ctl_rx,
				chunk_size = 32,
				transfer_phase_timeout_s = 1.0,
			})
		end)
		assert(ok, tostring(err))

		local reply1, err1
		local ok1, spawn1 = scope:spawn(function ()
			reply1, err1 = env.rpc_caller:call(env.topic, {
				op = 'send_blob',
				link_id = 'link-x4',
				source = 'first',
			}, { timeout = 1.0 })
		end)
		assert(ok1, tostring(spawn1))

		local begin = recv_mailbox(env.tx_control_rx).frame
		assert(begin.type == 'xfer_begin')

		local reply2, err2 = env.rpc_caller:call(env.topic, {
			op = 'send_blob',
			link_id = 'link-x4',
			source = 'second',
		}, { timeout = 0.5 })
		assert(reply2 == nil)
		assert(tostring(err2):match('busy'))

		env.xfer_tx:send({ msg = { type = 'xfer_ready', xfer_id = begin.xfer_id } })
		assert(recv_mailbox(env.tx_bulk_rx).frame.type == 'xfer_chunk')
		env.xfer_tx:send({ msg = { type = 'xfer_need', xfer_id = begin.xfer_id, next = #'first' } })
		assert(recv_mailbox(env.tx_control_rx).frame.type == 'xfer_commit')
		env.xfer_tx:send({ msg = { type = 'xfer_done', xfer_id = begin.xfer_id } })

		assert(probe.wait_until(function () return reply1 ~= nil end, { timeout = 0.5, interval = 0.01 }))
		assert(err1 == nil)
		assert(reply1.ok == true)
	end)
end

return T
