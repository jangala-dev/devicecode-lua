local mailbox   = require 'fibers.mailbox'
local runfibers = require 'tests.support.run_fibers'
local fakes     = require 'tests.support.fabric_fakes'
local protocol  = require 'services.fabric.protocol'
local writer    = require 'services.fabric.writer'

local T = {}

local function new_queues()
	local tx_control_tx, tx_control_rx = mailbox.new(16, { full = 'reject_newest' })
	local tx_rpc_tx, tx_rpc_rx = mailbox.new(16, { full = 'reject_newest' })
	local tx_bulk_tx, tx_bulk_rx = mailbox.new(16, { full = 'reject_newest' })
	local status_tx, status_rx = mailbox.new(16, { full = 'reject_newest' })
	return {
		tx_control_tx = tx_control_tx,
		tx_control_rx = tx_control_rx,
		tx_rpc_tx = tx_rpc_tx,
		tx_rpc_rx = tx_rpc_rx,
		tx_bulk_tx = tx_bulk_tx,
		tx_bulk_rx = tx_bulk_rx,
		status_tx = status_tx,
		status_rx = status_rx,
	}
end

local function push_item(tx, class, frame)
	local item, err = protocol.writer_item(class, frame)
	assert(item ~= nil, tostring(err))
	local ok, reason = tx:send(item)
	assert(ok == true, tostring(reason))
end

function T.writer_prioritises_control_over_other_lanes()
	runfibers.run(function(scope)
		local transport = fakes.new_transport()
		local q = new_queues()

		local ok, err = scope:spawn(function ()
			writer.run({
				transport = transport,
				tx_control = q.tx_control_rx,
				tx_rpc = q.tx_rpc_rx,
				tx_bulk = q.tx_bulk_rx,
				status_tx = q.status_tx,
				rpc_quantum = 2,
				bulk_quantum = 1,
			})
		end)
		assert(ok, tostring(err))

		push_item(q.tx_rpc_tx, 'rpc', { type = 'pub', topic = { 'rpc', 'one' }, payload = 1, retain = false })
		push_item(q.tx_bulk_tx, 'bulk', { type = 'xfer_chunk', xfer_id = 'x1', offset = 0, data = 'aaa' })
		push_item(q.tx_control_tx, 'control', { type = 'ping', sid = 'sid-a' })

		assert(fakes.wait_write_count(transport, 3, 1.0))
		local frames = fakes.decode_writes(transport)
		assert(frames[1].type == 'ping')
		assert(frames[2].type == 'pub')
		assert(frames[3].type == 'xfer_chunk')
	end)
end

function T.writer_applies_weighted_round_robin_between_rpc_and_bulk()
	runfibers.run(function(scope)
		local transport = fakes.new_transport()
		local q = new_queues()

		local ok, err = scope:spawn(function ()
			writer.run({
				transport = transport,
				tx_control = q.tx_control_rx,
				tx_rpc = q.tx_rpc_rx,
				tx_bulk = q.tx_bulk_rx,
				status_tx = q.status_tx,
				rpc_quantum = 2,
				bulk_quantum = 1,
			})
		end)
		assert(ok, tostring(err))

		push_item(q.tx_rpc_tx, 'rpc', { type = 'pub', topic = { 'rpc', 'a1' }, payload = 'a1', retain = false })
		push_item(q.tx_rpc_tx, 'rpc', { type = 'pub', topic = { 'rpc', 'a2' }, payload = 'a2', retain = false })
		push_item(q.tx_rpc_tx, 'rpc', { type = 'pub', topic = { 'rpc', 'a3' }, payload = 'a3', retain = false })
		push_item(q.tx_bulk_tx, 'bulk', { type = 'xfer_chunk', xfer_id = 'x1', offset = 0, data = 'b1' })
		push_item(q.tx_bulk_tx, 'bulk', { type = 'xfer_chunk', xfer_id = 'x1', offset = 2, data = 'b2' })

		assert(fakes.wait_write_count(transport, 5, 1.0))
		local frames = fakes.decode_writes(transport)
		assert(frames[1].payload == 'a1')
		assert(frames[2].payload == 'a2')
		assert(frames[3].type == 'xfer_chunk' and frames[3].data == 'b1')
		assert(frames[4].payload == 'a3')
		assert(frames[5].type == 'xfer_chunk' and frames[5].data == 'b2')
	end)
end

function T.writer_reports_tx_activity_for_each_write()
	runfibers.run(function(scope)
		local transport = fakes.new_transport()
		local q = new_queues()

		local ok, err = scope:spawn(function ()
			writer.run({
				transport = transport,
				tx_control = q.tx_control_rx,
				tx_rpc = q.tx_rpc_rx,
				tx_bulk = q.tx_bulk_rx,
				status_tx = q.status_tx,
			})
		end)
		assert(ok, tostring(err))

		push_item(q.tx_control_tx, 'control', { type = 'ping', sid = 'sid-a' })
		push_item(q.tx_rpc_tx, 'rpc', { type = 'pub', topic = { 'rpc', 'x' }, payload = true, retain = false })

		local s1 = assert(select(1, q.status_rx:recv()))
		local s2 = assert(select(1, q.status_rx:recv()))
		assert(s1.kind == 'tx_activity')
		assert(s2.kind == 'tx_activity')
		assert(type(s1.at) == 'number')
		assert(type(s2.at) == 'number')
	end)
end

function T.writer_fails_on_transport_write_error()
	runfibers.run(function(scope)
		local transport = fakes.new_transport()
		local q = new_queues()
		local child, cerr = scope:child()
		assert(child ~= nil, tostring(cerr))

		local ok, err = child:spawn(function ()
			writer.run({
				transport = transport,
				tx_control = q.tx_control_rx,
				tx_rpc = q.tx_rpc_rx,
				tx_bulk = q.tx_bulk_rx,
				status_tx = q.status_tx,
			})
		end)
		assert(ok, tostring(err))

		transport:fail_next_write('boom')
		push_item(q.tx_control_tx, 'control', { type = 'ping', sid = 'sid-fail' })

		local st, rep, primary = require('fibers').perform(child:join_op())
		assert(st == 'failed', tostring(primary))
		assert(tostring(primary):match('transport_write_failed'))
		assert(type(rep) == 'table')
	end)
end

return T
