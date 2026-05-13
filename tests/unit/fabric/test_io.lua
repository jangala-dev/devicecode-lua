-- tests/unit/fabric/test_io.lua

local fibers  = require 'fibers'
local op      = require 'fibers.op'
local sleep   = require 'fibers.sleep'
local mailbox = require 'fibers.mailbox'

local io_mod = require 'services.fabric.io'
local link   = require 'services.fabric.link'
local queue  = require 'devicecode.support.queue'

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

local function assert_match(s, pat, msg)
	if type(s) ~= 'string' or not s:match(pat) then
		fail(msg or ('expected "' .. tostring(s) .. '" to match ' .. tostring(pat)))
	end
end

local function frames_reader(frames)
	local i = 0

	return function ()
		return op.guard(function ()
			i = i + 1

			local frame = frames[i]
			if frame == nil then
				return op.always(nil, 'eof')
			end

			return op.always(frame, nil)
		end)
	end
end

local function closed_rx(reason)
	local tx, rx = mailbox.new(1, { full = 'reject_newest' })
	tx:close(reason or 'closed')
	return rx
end

local function send_frame(tx, frame, label)
	return queue.try_admit_required(tx, {
		kind  = 'send_frame',
		frame = frame,
	}, label or 'send_frame')
end

-------------------------------------------------------------------------------
-- Reader forwards frames and returns a result table
-------------------------------------------------------------------------------

function tests.test_reader_forwards_frames_and_returns_count()
	fibers.run(function (scope)
		local tx, rx = mailbox.new(8, { full = 'reject_newest' })

		local result = io_mod.run_reader(scope, {
			read_frame_op = frames_reader { 'a', 'b' },
			downstream_tx = tx,
		})

		assert_eq(result.role, 'reader')
		assert_eq(result.frames_read, 2)
		assert_eq(result.reason, 'eof')

		local ev1 = fibers.perform(rx:recv_op())
		local ev2 = fibers.perform(rx:recv_op())

		assert_eq(ev1.kind, 'frame_received')
		assert_eq(ev1.frame, 'a')

		assert_eq(ev2.kind, 'frame_received')
		assert_eq(ev2.frame, 'b')
	end)
end

-------------------------------------------------------------------------------
-- Reader may deliberately block on downstream handoff
-------------------------------------------------------------------------------

function tests.test_reader_blocks_on_downstream_handoff()
	fibers.run(function (scope)
		local downstream_tx, downstream_rx = mailbox.new(0, { full = 'block' })
		local done_tx, done_rx = mailbox.new(1, { full = 'reject_newest' })

		local ok, err = scope:spawn(function ()
			local result = io_mod.run_reader(scope, {
				read_frame_op = frames_reader { 'blocked-frame' },
				downstream_tx = downstream_tx,
			})

			queue.try_admit_required(done_tx, result, 'reader_done')
		end)

		assert_true(ok, err)

		fibers.perform(sleep.sleep_op(0.001))

		local done_now, done_err = queue.try_recv_now(done_rx)
		assert_nil(done_now)
		assert_eq(done_err, 'not_ready')

		local ev = fibers.perform(downstream_rx:recv_op())
		assert_not_nil(ev)
		assert_eq(ev.kind, 'frame_received')
		assert_eq(ev.frame, 'blocked-frame')

		local result = fibers.perform(done_rx:recv_op())
		assert_eq(result.role, 'reader')
		assert_eq(result.frames_read, 1)
		assert_eq(result.reason, 'eof')
	end)
end

-------------------------------------------------------------------------------
-- Reader read errors fail the owning scope
-------------------------------------------------------------------------------

function tests.test_reader_read_error_fails_scope()
	fibers.run(function ()
		local tx = mailbox.new(4, { full = 'reject_newest' })

		local st, _, primary = fibers.run_scope(function (scope)
			return io_mod.run_reader(scope, {
				read_frame_op = function ()
					return op.always(nil, 'transport exploded')
				end,
				downstream_tx = tx,
			})
		end)

		assert_eq(st, 'failed')
		assert_match(primary, 'reader read failed')
		assert_match(primary, 'transport exploded')
	end)
end

-------------------------------------------------------------------------------
-- Lane writer writes queued frames and flushes on close
-------------------------------------------------------------------------------

function tests.test_lane_writer_writes_frames_and_flushes_on_close()
	fibers.run(function (scope)
		local rpc_tx, rpc_rx = mailbox.new(8, { full = 'reject_newest' })
		local written = {}
		local flushes = 0

		send_frame(rpc_tx, 'a', 'rpc_a')
		send_frame(rpc_tx, 'b', 'rpc_b')
		rpc_tx:close('rpc_done')

		local result = io_mod.run_lane_writer(scope, {
			control_rx = closed_rx('control_done'),
			rpc_rx = rpc_rx,
			bulk_rx = closed_rx('bulk_done'),

			write_frame_op = function (frame)
				return op.guard(function ()
					written[#written + 1] = frame
					return op.always(true, nil)
				end)
			end,

			flush_op = function ()
				return op.guard(function ()
					flushes = flushes + 1
					return op.always(true, nil)
				end)
			end,
		})

		assert_eq(result.role, 'writer')
		assert_eq(result.frames_written, 2)
		assert_eq(result.reason, 'closed')
		assert_eq(result.lanes.rpc, 2)

		assert_eq(written[1], 'a')
		assert_eq(written[2], 'b')
		assert_eq(flushes, 1)
	end)
end

-------------------------------------------------------------------------------
-- Lane writer can flush each frame when asked
-------------------------------------------------------------------------------

function tests.test_lane_writer_can_flush_each_frame()
	fibers.run(function (scope)
		local rpc_tx, rpc_rx = mailbox.new(8, { full = 'reject_newest' })
		local flushes = 0

		send_frame(rpc_tx, 'a', 'rpc_a')
		send_frame(rpc_tx, 'b', 'rpc_b')
		rpc_tx:close('rpc_done')

		local result = io_mod.run_lane_writer(scope, {
			control_rx = closed_rx('control_done'),
			rpc_rx = rpc_rx,
			bulk_rx = closed_rx('bulk_done'),
			flush_each = true,

			write_frame_op = function ()
				return op.always(true, nil)
			end,

			flush_op = function ()
				return op.guard(function ()
					flushes = flushes + 1
					return op.always(true, nil)
				end)
			end,
		})

		assert_eq(result.frames_written, 2)
		assert_eq(flushes, 3)
	end)
end

-------------------------------------------------------------------------------
-- Lane writer write errors fail the owning scope
-------------------------------------------------------------------------------

function tests.test_lane_writer_write_error_fails_scope()
	fibers.run(function ()
		local rpc_tx, rpc_rx = mailbox.new(8, { full = 'reject_newest' })
		send_frame(rpc_tx, 'bad-frame', 'rpc_bad')
		rpc_tx:close('rpc_done')

		local st, _, primary = fibers.run_scope(function (scope)
			return io_mod.run_lane_writer(scope, {
				control_rx = closed_rx('control_done'),
				rpc_rx = rpc_rx,
				bulk_rx = closed_rx('bulk_done'),

				write_frame_op = function ()
					return op.always(nil, 'write exploded')
				end,
			})
		end)

		assert_eq(st, 'failed')
		assert_match(primary, 'writer write failed')
		assert_match(primary, 'write exploded')
	end)
end

-------------------------------------------------------------------------------
-- Reader and lane writer owners fit the link supervisor
-------------------------------------------------------------------------------

function tests.test_reader_and_writer_components_fit_link_supervisor()
	fibers.run(function ()
		local frame_tx, frame_rx = mailbox.new(8, { full = 'reject_newest' })
		local rpc_tx, rpc_rx = mailbox.new(8, { full = 'reject_newest' })
		local written = {}

		send_frame(rpc_tx, 'out-a', 'outbound')
		rpc_tx:close('rpc_done')

		local st, _, result = fibers.run_scope(function (scope)
			return link.run(scope, {
				link_id = 'link-io',

				components = {
					{
						name = 'reader',
						run = function (component_scope)
							return io_mod.run_reader(component_scope, {
								read_frame_op = frames_reader { 'in-a' },
								downstream_tx = frame_tx,
							})
						end,
					},

					{
						name = 'writer',
						run = function (component_scope)
							return io_mod.run_lane_writer(component_scope, {
								control_rx = closed_rx('control_done'),
								rpc_rx = rpc_rx,
								bulk_rx = closed_rx('bulk_done'),

								write_frame_op = function (frame)
									return op.guard(function ()
										written[#written + 1] = frame
										return op.always(true, nil)
									end)
								end,
							})
						end,
					},
				},
			})
		end)

		assert_eq(st, 'ok')
		assert_not_nil(result)

		local snap = result.snapshot
		assert_eq(snap.state, 'completed')
		assert_eq(snap.components.reader.status, 'ok')
		assert_eq(snap.components.writer.status, 'ok')

		assert_eq(snap.components.reader.result.frames_read, 1)
		assert_eq(snap.components.writer.result.frames_written, 1)
		assert_eq(written[1], 'out-a')

		local ev = fibers.perform(frame_rx:recv_op())
		assert_eq(ev.kind, 'frame_received')
		assert_eq(ev.frame, 'in-a')
	end)
end

-------------------------------------------------------------------------------
-- Lane writer treats nil,nil write results as an invalid ambiguous failure
-------------------------------------------------------------------------------

function tests.test_lane_writer_rejects_ambiguous_nil_nil_write_result()
	fibers.run(function ()
		local rpc_tx, rpc_rx = mailbox.new(8, { full = 'reject_newest' })
		send_frame(rpc_tx, 'ambiguous-frame', 'rpc_ambiguous')
		rpc_tx:close('rpc_done')

		local st, _, primary = fibers.run_scope(function (scope)
			return io_mod.run_lane_writer(scope, {
				control_rx = closed_rx('control_done'),
				rpc_rx = rpc_rx,
				bulk_rx = closed_rx('bulk_done'),

				write_frame_op = function ()
					return op.always()
				end,
			})
		end)

		assert_eq(st, 'failed')
		assert_match(primary, 'writer write failed')
		assert_match(primary, 'write_failed')
	end)
end

-------------------------------------------------------------------------------
-- Lane writer treats nil,nil flush results as an invalid ambiguous failure
-------------------------------------------------------------------------------

function tests.test_lane_writer_rejects_ambiguous_nil_nil_flush_result()
	fibers.run(function ()
		local st, _, primary = fibers.run_scope(function (scope)
			return io_mod.run_lane_writer(scope, {
				control_rx = closed_rx('control_done'),
				rpc_rx = closed_rx('rpc_done'),
				bulk_rx = closed_rx('bulk_done'),

				write_frame_op = function ()
					return op.always(true, nil)
				end,

				flush_op = function ()
					return op.always()
				end,
			})
		end)

		assert_eq(st, 'failed')
		assert_match(primary, 'writer flush failed')
		assert_match(primary, 'flush_failed')
	end)
end

return tests
