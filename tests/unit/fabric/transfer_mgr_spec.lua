local busmod     = require 'bus'
local fibers     = require 'fibers'
local mailbox    = require 'fibers.mailbox'
local sleep      = require 'fibers.sleep'
local runfibers  = require 'tests.support.run_fibers'
local probe      = require 'tests.support.bus_probe'

local session_ctl  = require 'services.fabric.session_ctl'
local transfer_mgr = require 'services.fabric.transfer_mgr'
local checksum     = require 'services.fabric.checksum'

local T = {}

local function recv_with_timeout(rx, timeout)
	local which, a, b = fibers.perform(fibers.named_choice({
		msg = rx:recv_op(),
		timer = sleep.sleep_op(timeout):wrap(function() return true end),
	}))
	if which == 'timer' then
		return nil, 'timeout'
	end
	return a, b
end

local function new_env(bus, link_id)
	local state_conn = bus:connect()
	local session = session_ctl.new_state(link_id, state_conn)
	local xfer_tx, xfer_rx = mailbox.new(64, { full = 'reject_newest' })
	local status_tx, status_rx = mailbox.new(64, { full = 'reject_newest' })
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
		status_tx = status_tx,
		status_rx = status_rx,
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

local function new_request(payload)
	local req = {
		payload = payload,
		_done = false,
		reply_payload = nil,
		fail_err = nil,
	}

	function req:done()
		return self._done
	end

	function req:reply(value)
		self._done = true
		self.reply_payload = value
		return true
	end

	function req:fail(err)
		self._done = true
		self.fail_err = err
		return true
	end

	return req
end

local function send_request(env, payload)
	local req = new_request(payload)
	local ok, err = env.transfer_ctl_tx:send(req)
	assert(ok == true, tostring(err))
	return req
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
				status_tx = env.status_tx,
				tx_control = env.tx_control_tx,
				tx_bulk = env.tx_bulk_tx,
				transfer_ctl_rx = env.transfer_ctl_rx,
				chunk_size = 32,
				transfer_phase_timeout_s = 0.5,
			})
		end)
		assert(ok, tostring(err))

		local req = send_request(env, {
			op = 'send_blob',
			link_id = 'link-x1',
			source = 'hello world',
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
		assert(probe.wait_until(function () return req:done() end, { timeout = 0.5, interval = 0.01 }))
		assert(req.fail_err == nil)
		assert(req.reply_payload.ok == true)
		assert(req.reply_payload.xfer_id == begin.xfer_id)
		assert(req.reply_payload.size == #'hello world')
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
				status_tx = env.status_tx,
				tx_control = env.tx_control_tx,
				tx_bulk = env.tx_bulk_tx,
				transfer_ctl_rx = env.transfer_ctl_rx,
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

		local ok, err = scope:spawn(function ()
			transfer_mgr.run({
				link_id = 'link-x3',
				conn = env.conn,
				session = env.session,
				xfer_rx = env.xfer_rx,
				status_tx = env.status_tx,
				tx_control = env.tx_control_tx,
				tx_bulk = env.tx_bulk_tx,
				transfer_ctl_rx = env.transfer_ctl_rx,
				chunk_size = 4,
				transfer_phase_timeout_s = 1.0,
			})
		end)
		assert(ok, tostring(err))

		local req = send_request(env, {
			op = 'send_blob',
			link_id = 'link-x3',
			source = 'abcdefgh',
		})

		local begin = recv_mailbox(env.tx_control_rx).frame
		assert(begin.type == 'xfer_begin')

		env.session:update(function (s)
			s.generation = s.generation + 1
		end, { bump_pulse = true })

		assert(probe.wait_until(function () return req:done() and tostring(req.fail_err):match('session_reset') ~= nil end,
			{ timeout = 0.5, interval = 0.01 }))
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
				status_tx = env.status_tx,
				tx_control = env.tx_control_tx,
				tx_bulk = env.tx_bulk_tx,
				transfer_ctl_rx = env.transfer_ctl_rx,
				chunk_size = 32,
				transfer_phase_timeout_s = 1.0,
			})
		end)
		assert(ok, tostring(err))

		local req1 = send_request(env, { op = 'send_blob', link_id = 'link-x4', source = 'first' })

		local begin = recv_mailbox(env.tx_control_rx).frame
		assert(begin.type == 'xfer_begin')

		local req2 = send_request(env, { op = 'send_blob', link_id = 'link-x4', source = 'second' })
		assert(probe.wait_until(function () return req2:done() end, { timeout = 0.5, interval = 0.01 }))
		assert(tostring(req2.fail_err):match('busy'))

		env.xfer_tx:send({ msg = { type = 'xfer_ready', xfer_id = begin.xfer_id } })
		assert(recv_mailbox(env.tx_bulk_rx).frame.type == 'xfer_chunk')
		env.xfer_tx:send({ msg = { type = 'xfer_need', xfer_id = begin.xfer_id, next = #'first' } })
		assert(recv_mailbox(env.tx_control_rx).frame.type == 'xfer_commit')
		env.xfer_tx:send({ msg = { type = 'xfer_done', xfer_id = begin.xfer_id } })

		assert(probe.wait_until(function () return req1:done() end, { timeout = 0.5, interval = 0.01 }))
		assert(req1.fail_err == nil)
		assert(req1.reply_payload.ok == true)
	end)
end

function T.outgoing_transfer_progress_is_throttled_while_sending()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local observer = bus:connect()
		local env = new_env(bus, 'link-x5')
		local source = string.rep('a', 33)

		local ok, err = scope:spawn(function ()
			transfer_mgr.run({
				link_id = 'link-x5',
				conn = env.conn,
				session = env.session,
				xfer_rx = env.xfer_rx,
				status_tx = env.status_tx,
				tx_control = env.tx_control_tx,
				tx_bulk = env.tx_bulk_tx,
				transfer_ctl_rx = env.transfer_ctl_rx,
				chunk_size = 1,
				transfer_phase_timeout_s = 1.0,
			})
		end)
		assert(ok, tostring(err))

		local transfer_sub = observer:subscribe({ 'state', 'fabric', 'link', 'link-x5', 'transfer' }, {
			queue_len = 16,
			full = 'drop_oldest',
		})

		local req = send_request(env, {
			op = 'send_blob',
			link_id = 'link-x5',
			source = source,
		})

		local begin = recv_mailbox(env.tx_control_rx).frame
		assert(begin.type == 'xfer_begin')

		env.xfer_tx:send({ msg = { type = 'xfer_ready', xfer_id = begin.xfer_id } })
		for i = 0, #source - 1 do
			local chunk = recv_mailbox(env.tx_bulk_rx).frame
			assert(chunk.type == 'xfer_chunk')
			assert(chunk.xfer_id == begin.xfer_id)
			assert(chunk.offset == i)
			assert(chunk.data == 'a')
			env.xfer_tx:send({ msg = { type = 'xfer_need', xfer_id = begin.xfer_id, next = i + 1 } })
		end

		local commit = recv_mailbox(env.tx_control_rx).frame
		assert(commit.type == 'xfer_commit')
		env.xfer_tx:send({ msg = { type = 'xfer_done', xfer_id = begin.xfer_id } })

		assert(probe.wait_until(function () return req:done() end, { timeout = 0.5, interval = 0.01 }))
		assert(req.fail_err == nil)

		local statuses = {}
		while true do
			local msg, serr = recv_with_timeout(transfer_sub, 0.25)
			assert(msg ~= nil, tostring(serr))
			statuses[#statuses + 1] = msg.payload.status
			if msg.payload.status.state == 'done' then
				break
			end
		end
		transfer_sub:unsubscribe()
		if statuses[1] and statuses[1].state == 'idle' then
			table.remove(statuses, 1)
		end

		assert(#statuses == 5)
		assert(statuses[1].state == 'waiting_ready' and statuses[1].offset == 0)
		assert(statuses[2].state == 'sending' and statuses[2].offset == 32)
		assert(statuses[3].state == 'sending' and statuses[3].offset == 33)
		assert(statuses[4].state == 'committing' and statuses[4].offset == 33)
		assert(statuses[5].state == 'done' and statuses[5].offset == 33)
	end)
end

function T.firmware_transfer_completion_requests_reconnect()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local env = new_env(bus, 'link-x6')

		local ok, err = scope:spawn(function ()
			transfer_mgr.run({
				link_id = 'link-x6',
				conn = env.conn,
				session = env.session,
				xfer_rx = env.xfer_rx,
				status_tx = env.status_tx,
				tx_control = env.tx_control_tx,
				tx_bulk = env.tx_bulk_tx,
				transfer_ctl_rx = env.transfer_ctl_rx,
				chunk_size = 32,
				transfer_phase_timeout_s = 1.0,
			})
		end)
		assert(ok, tostring(err))

		local req = send_request(env, {
			op = 'send_blob',
			link_id = 'link-x6',
			source = 'firmware',
			meta = { kind = 'firmware.rp2350' },
		})

		local begin = recv_mailbox(env.tx_control_rx).frame
		env.xfer_tx:send({ msg = { type = 'xfer_ready', xfer_id = begin.xfer_id } })
		assert(recv_mailbox(env.tx_bulk_rx).frame.type == 'xfer_chunk')
		env.xfer_tx:send({ msg = { type = 'xfer_need', xfer_id = begin.xfer_id, next = #'firmware' } })
		assert(recv_mailbox(env.tx_control_rx).frame.type == 'xfer_commit')
		env.xfer_tx:send({ msg = { type = 'xfer_done', xfer_id = begin.xfer_id } })

		assert(probe.wait_until(function () return req:done() end, { timeout = 0.5, interval = 0.01 }))
		assert(req.fail_err == nil)

		local status, serr = recv_with_timeout(env.status_rx, 0.25)
		assert(status ~= nil, tostring(serr))
		assert(status.kind == 'reconnect_requested')
	end)
end

function T.non_firmware_transfer_completion_does_not_request_reconnect()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local env = new_env(bus, 'link-x7')

		local ok, err = scope:spawn(function ()
			transfer_mgr.run({
				link_id = 'link-x7',
				conn = env.conn,
				session = env.session,
				xfer_rx = env.xfer_rx,
				status_tx = env.status_tx,
				tx_control = env.tx_control_tx,
				tx_bulk = env.tx_bulk_tx,
				transfer_ctl_rx = env.transfer_ctl_rx,
				chunk_size = 32,
				transfer_phase_timeout_s = 1.0,
			})
		end)
		assert(ok, tostring(err))

		local req = send_request(env, {
			op = 'send_blob',
			link_id = 'link-x7',
			source = 'payload',
			meta = { kind = 'blob' },
		})

		local begin = recv_mailbox(env.tx_control_rx).frame
		env.xfer_tx:send({ msg = { type = 'xfer_ready', xfer_id = begin.xfer_id } })
		assert(recv_mailbox(env.tx_bulk_rx).frame.type == 'xfer_chunk')
		env.xfer_tx:send({ msg = { type = 'xfer_need', xfer_id = begin.xfer_id, next = #'payload' } })
		assert(recv_mailbox(env.tx_control_rx).frame.type == 'xfer_commit')
		env.xfer_tx:send({ msg = { type = 'xfer_done', xfer_id = begin.xfer_id } })

		assert(probe.wait_until(function () return req:done() end, { timeout = 0.5, interval = 0.01 }))
		assert(req.fail_err == nil)

		local status, serr = recv_with_timeout(env.status_rx, 0.1)
		assert(status == nil)
		assert(serr == 'timeout')
	end)
end

return T
