local mailbox   = require 'fibers.mailbox'
local runfibers = require 'tests.support.run_fibers'
local fakes     = require 'tests.support.fabric_fakes'
local protocol  = require 'services.fabric.protocol'
local reader    = require 'services.fabric.reader'

local T = {}

local function new_stub_svc()
	return {
		obs_log = function() end,
	}
end

function T.reader_classifies_frames_and_emits_rx_activity()
	runfibers.run(function(scope)
		local transport = fakes.new_transport()
		local control_tx, control_rx = mailbox.new(8, { full = 'reject_newest' })
		local rpc_tx, rpc_rx = mailbox.new(8, { full = 'reject_newest' })
		local xfer_tx, xfer_rx = mailbox.new(8, { full = 'reject_newest' })
		local status_tx, status_rx = mailbox.new(8, { full = 'reject_newest' })

		local ok, err = scope:spawn(function ()
			reader.run({
				transport = transport,
				link_id = 'link-r1',
				svc = new_stub_svc(),
				control_tx = control_tx,
				rpc_tx = rpc_tx,
				xfer_tx = xfer_tx,
				status_tx = status_tx,
				read_timeout_s = 0.05,
			})
		end)
		assert(ok, tostring(err))

		transport:inject_line(assert(protocol.encode_line({ type = 'hello', sid = 'peer-1', node = 'peer' })))
		transport:inject_line(assert(protocol.encode_line({ type = 'pub', topic = { 'remote', 'x' }, payload = { ok = true }, retain = false })))
		transport:inject_line(assert(protocol.encode_line({ type = 'xfer_begin', xfer_id = 'x1', size = 0, checksum = 'abc' })))

		local s1 = assert(select(1, status_rx:recv()))
		local c1 = assert(select(1, control_rx:recv()))
		local s2 = assert(select(1, status_rx:recv()))
		local r1 = assert(select(1, rpc_rx:recv()))
		local s3 = assert(select(1, status_rx:recv()))
		local x1 = assert(select(1, xfer_rx:recv()))

		assert(s1.kind == 'rx_activity')
		assert(c1.msg.type == 'hello')
		assert(s2.kind == 'rx_activity')
		assert(r1.msg.type == 'pub')
		assert(s3.kind == 'rx_activity')
		assert(x1.msg.type == 'xfer_begin')
	end)
end

function T.reader_tolerates_timeouts_until_a_valid_frame_arrives()
	runfibers.run(function(scope)
		local transport = fakes.new_transport()
		local control_tx, control_rx = mailbox.new(8, { full = 'reject_newest' })
		local rpc_tx, rpc_rx = mailbox.new(8, { full = 'reject_newest' })
		local xfer_tx, xfer_rx = mailbox.new(8, { full = 'reject_newest' })
		local status_tx, status_rx = mailbox.new(8, { full = 'reject_newest' })

		local ok, err = scope:spawn(function ()
			reader.run({
				transport = transport,
				link_id = 'link-r2',
				svc = new_stub_svc(),
				control_tx = control_tx,
				rpc_tx = rpc_tx,
				xfer_tx = xfer_tx,
				status_tx = status_tx,
				read_timeout_s = 0.02,
			})
		end)
		assert(ok, tostring(err))

		require('fibers.sleep').sleep(0.06)
		transport:inject_line(assert(protocol.encode_line({ type = 'reply', id = 'r1', ok = true, value = { ok = true } })))

		local stat = assert(select(1, status_rx:recv()))
		local msg = assert(select(1, rpc_rx:recv()))
		assert(stat.kind == 'rx_activity')
		assert(msg.msg.type == 'reply')
	end)
end

function T.reader_fails_after_too_many_bad_frames()
	runfibers.run(function(scope)
		local transport = fakes.new_transport()
		local control_tx, control_rx = mailbox.new(8, { full = 'reject_newest' })
		local rpc_tx, rpc_rx = mailbox.new(8, { full = 'reject_newest' })
		local xfer_tx, xfer_rx = mailbox.new(8, { full = 'reject_newest' })
		local status_tx, status_rx = mailbox.new(8, { full = 'reject_newest' })
		local child, cerr = scope:child()
		assert(child ~= nil, tostring(cerr))

		local ok, err = child:spawn(function ()
			reader.run({
				transport = transport,
				link_id = 'link-r3',
				svc = new_stub_svc(),
				control_tx = control_tx,
				rpc_tx = rpc_tx,
				xfer_tx = xfer_tx,
				status_tx = status_tx,
				bad_frame_limit = 2,
				bad_frame_window_s = 10.0,
				read_timeout_s = 0.02,
			})
		end)
		assert(ok, tostring(err))

		transport:inject_line('not-json')
		transport:inject_line('still-not-json')

		local st, rep, primary = require('fibers').perform(child:join_op())
		assert(st == 'failed', tostring(primary))
		assert(tostring(primary):match('too_many_bad_frames'))
		assert(type(rep) == 'table')
	end)
end

return T
