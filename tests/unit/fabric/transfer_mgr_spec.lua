local busmod     = require 'bus'
local mailbox    = require 'fibers.mailbox'
local runfibers  = require 'tests.support.run_fibers'
local probe      = require 'tests.support.bus_probe'

local session_ctl  = require 'services.fabric.session_ctl'
local transfer_mgr = require 'services.fabric.transfer_mgr'
local blob_source  = require 'services.fabric.blob_source'
local checksum     = require 'services.fabric.checksum'

local T = {}

local function new_env(bus, link_id)
	local state_conn = bus:connect()
	local session = session_ctl.new_state(link_id, state_conn)
	local xfer_tx, xfer_rx = mailbox.new(64, { full = 'reject_newest' })
	local tx_control_tx, tx_control_rx = mailbox.new(64, { full = 'reject_newest' })
	local tx_bulk_tx, tx_bulk_rx = mailbox.new(64, { full = 'reject_newest' })
	local transfer_ctl_tx, transfer_ctl_rx = mailbox.new(16, { full = 'reject_newest' })
	local status_tx, status_rx = mailbox.new(64, { full = 'reject_newest' })
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
		status_tx = status_tx,
		status_rx = status_rx,
	}
end

local function recv_mailbox(rx)
	local item, err = rx:recv()
	assert(item ~= nil, tostring(err))
	return item
end

local function new_reply_box()
	local tx, rx = mailbox.new(1, { full = 'reject_newest' })
	return tx, rx
end

function T.outgoing_transfer_happy_path_emits_begin_chunk_commit_and_reply()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local env = new_env(bus, 'link-x1')

		local ok, err = scope:spawn(function ()
			transfer_mgr.run({
				link_id = 'link-x1',
				conn = env.conn,
				session = env.session,
				xfer_rx = env.xfer_rx,
				tx_control = env.tx_control_tx,
				tx_bulk = env.tx_bulk_tx,
				transfer_ctl_rx = env.transfer_ctl_rx,
				status_tx = env.status_tx,
				chunk_size = 32,
				transfer_phase_timeout_s = 0.5,
			})
		end)
		assert(ok, tostring(err))

		local reply_tx, reply_rx = new_reply_box()
		env.transfer_ctl_tx:send({
			op = 'send_blob',
			link_id = 'link-x1',
			source = 'hello world',
			reply_tx = reply_tx,
		})

		local begin = recv_mailbox(env.tx_control_rx).frame
		assert(begin.type == 'xfer_begin')
		assert(begin.size == #'hello world')

		env.xfer_tx:send({ msg = { type = 'xfer_ready', xfer_id = begin.xfer_id } })
		local chunk = recv_mailbox(env.tx_bulk_rx).frame
		assert(chunk.type == 'xfer_chunk')
		assert(chunk.xfer_id == begin.xfer_id)
		assert(chunk.offset == 0)
		assert(chunk.data == 'hello world')

		env.xfer_tx:send({ msg = { type = 'xfer_need', xfer_id = begin.xfer_id, next = #'hello world' } })
		local commit = recv_mailbox(env.tx_control_rx).frame
		assert(commit.type == 'xfer_commit')
		assert(commit.xfer_id == begin.xfer_id)
		assert(commit.size == #'hello world')

		env.xfer_tx:send({ msg = { type = 'xfer_done', xfer_id = begin.xfer_id } })
		local reply = recv_mailbox(reply_rx)
		assert(reply.ok == true)
		assert(reply.xfer_id == begin.xfer_id)
		assert(reply.size == #'hello world')
	end)
end

function T.incoming_transfer_happy_path_accepts_chunks_and_commits()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local observer = bus:connect()
		local env = new_env(bus, 'link-x2')
		local data = 'payload'
		local digest = checksum.digest_hex(data)

		local ok, err = scope:spawn(function ()
			transfer_mgr.run({
				link_id = 'link-x2',
				conn = env.conn,
				session = env.session,
				xfer_rx = env.xfer_rx,
				tx_control = env.tx_control_tx,
				tx_bulk = env.tx_bulk_tx,
				transfer_ctl_rx = env.transfer_ctl_rx,
				status_tx = env.status_tx,
				chunk_size = 32,
				transfer_phase_timeout_s = 0.5,
			})
		end)
		assert(ok, tostring(err))

		env.xfer_tx:send({ msg = { type = 'xfer_begin', xfer_id = 'in-1', size = #data, checksum = digest, meta = { name = 'blob' } } })
		local ready = recv_mailbox(env.tx_control_rx).frame
		assert(ready.type == 'xfer_ready')
		assert(ready.xfer_id == 'in-1')

		env.xfer_tx:send({ msg = { type = 'xfer_chunk', xfer_id = 'in-1', offset = 0, data = data } })
		local need = recv_mailbox(env.tx_control_rx).frame
		assert(need.type == 'xfer_need')
		assert(need.next == #data)

		env.xfer_tx:send({ msg = { type = 'xfer_commit', xfer_id = 'in-1', size = #data, checksum = digest } })
		local done = recv_mailbox(env.tx_control_rx).frame
		assert(done.type == 'xfer_done')
		assert(done.xfer_id == 'in-1')

		local retained = probe.wait_payload(observer, { 'state', 'fabric', 'link', 'link-x2', 'transfer' }, { timeout = 0.25 })
		assert(retained.state == 'done')
		assert(retained.direction == 'in')
		assert(retained.xfer_id == 'in-1')
	end)
end

function T.session_generation_change_aborts_outgoing_transfer()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local env = new_env(bus, 'link-x3')

		local ok, err = scope:spawn(function ()
			transfer_mgr.run({
				link_id = 'link-x3',
				conn = env.conn,
				session = env.session,
				xfer_rx = env.xfer_rx,
				tx_control = env.tx_control_tx,
				tx_bulk = env.tx_bulk_tx,
				transfer_ctl_rx = env.transfer_ctl_rx,
				status_tx = env.status_tx,
				chunk_size = 4,
				transfer_phase_timeout_s = 1.0,
			})
		end)
		assert(ok, tostring(err))

		local reply_tx, reply_rx = new_reply_box()
		env.transfer_ctl_tx:send({
			op = 'send_blob',
			link_id = 'link-x3',
			source = 'abcdefgh',
			reply_tx = reply_tx,
		})

		local begin = recv_mailbox(env.tx_control_rx).frame
		assert(begin.type == 'xfer_begin')

		env.session:update(function (s)
			s.generation = s.generation + 1
		end, { bump_pulse = true })

		local reply = recv_mailbox(reply_rx)
		assert(reply.ok == false)
		assert(tostring(reply.err):match('session_reset'))
	end)
end

function T.only_one_outgoing_transfer_is_admitted_at_a_time()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local env = new_env(bus, 'link-x4')

		local ok, err = scope:spawn(function ()
			transfer_mgr.run({
				link_id = 'link-x4',
				conn = env.conn,
				session = env.session,
				xfer_rx = env.xfer_rx,
				tx_control = env.tx_control_tx,
				tx_bulk = env.tx_bulk_tx,
				transfer_ctl_rx = env.transfer_ctl_rx,
				status_tx = env.status_tx,
				chunk_size = 32,
				transfer_phase_timeout_s = 1.0,
			})
		end)
		assert(ok, tostring(err))

		local reply1_tx, reply1_rx = new_reply_box()
		local reply2_tx, reply2_rx = new_reply_box()
		env.transfer_ctl_tx:send({ op = 'send_blob', link_id = 'link-x4', source = 'first', reply_tx = reply1_tx })
		env.transfer_ctl_tx:send({ op = 'send_blob', link_id = 'link-x4', source = 'second', reply_tx = reply2_tx })

		local begin = recv_mailbox(env.tx_control_rx).frame
		assert(begin.type == 'xfer_begin')
		local reply2 = recv_mailbox(reply2_rx)
		assert(reply2.ok == false)
		assert(tostring(reply2.err):match('busy'))

		env.xfer_tx:send({ msg = { type = 'xfer_ready', xfer_id = begin.xfer_id } })
		assert(recv_mailbox(env.tx_bulk_rx).frame.type == 'xfer_chunk')
		env.xfer_tx:send({ msg = { type = 'xfer_need', xfer_id = begin.xfer_id, next = #'first' } })
		assert(recv_mailbox(env.tx_control_rx).frame.type == 'xfer_commit')
		env.xfer_tx:send({ msg = { type = 'xfer_done', xfer_id = begin.xfer_id } })
		local reply1 = recv_mailbox(reply1_rx)
		assert(reply1.ok == true)
	end)
end

return T
