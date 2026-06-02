-- tests/unit/fabric/test_io.lua

local fibers  = require 'fibers'
local op      = require 'fibers.op'
local sleep   = require 'fibers.sleep'
local mailbox = require 'fibers.mailbox'

local io_mod = require 'services.fabric.io'
local hal_transport = require 'services.fabric.hal_transport'
local link   = require 'services.fabric.link'
local protocol = require 'services.fabric.protocol'
local queue  = require 'devicecode.support.queue'
local xxhash32 = require 'shared.hash.xxhash32'

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

local function read_results(results)
	local i = 0
	return function ()
		return op.guard(function ()
			i = i + 1
			local item = results[i]
			if item == nil then
				return op.always(nil, 'eof')
			end
			if item.err ~= nil then
				return op.always(nil, item.err)
			end
			return op.always(item.frame, nil)
		end)
	end
end

local function raw_line_transport(lines)
	local i = 0
	return {
		read_line_op = function ()
			return op.guard(function ()
				i = i + 1
				local line = lines[i]
				if line == nil then
					return op.always(nil, 'eof')
				end
				return op.always(line, nil)
			end)
		end,
		write_line_op = function ()
			return op.always(true, nil)
		end,
		terminate = function () return true, nil end,
	}
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

local function capture_prints(fn)
	local old_print = _G.print
	local lines = {}
	_G.print = function (...)
		local parts = {}
		for i = 1, select('#', ...) do
			parts[#parts + 1] = tostring(select(i, ...))
		end
		lines[#lines + 1] = table.concat(parts, '\t')
	end
	local ok, err = pcall(fn, lines)
	_G.print = old_print
	if not ok then error(err, 0) end
	return lines
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

function tests.test_reader_forwards_wire_errors_below_recovery_limit()
	fibers.run(function (scope)
		local tx, rx = mailbox.new(8, { full = 'reject_newest' })

		local result = io_mod.run_reader(scope, {
			read_frame_op = read_results {
				{ err = 'decode_failed: first' },
			},
			downstream_tx = tx,
			bad_frame_limit = 2,
			bad_frame_window_s = 10,
		})

		assert_eq(result.role, 'reader')
		assert_eq(result.wire_errors, 1)

		local ev = fibers.perform(rx:recv_op())
		assert_eq(ev.kind, 'wire_error')
		assert_eq(ev.err, 'decode_failed: first')
		assert_eq(ev.wire_errors, 1)
		assert_eq(ev.bad_frame_count, 1)
	end)
end

function tests.test_reader_wire_error_includes_bad_line_diagnostics_from_hal_transport()
	fibers.run(function (scope)
		local tx, rx = mailbox.new(8, { full = 'reject_newest' })
		local line = '[mem] boot\r\n{"type":"hello"'
		local wrapped = assert(hal_transport.wrap_transport(raw_line_transport { line }))

		local result = io_mod.run_reader(scope, {
			read_frame_op = function () return wrapped:read_frame_op() end,
			downstream_tx = tx,
			bad_frame_limit = 3,
			bad_frame_window_s = 10,
		})

		assert_eq(result.role, 'reader')
		assert_eq(result.wire_errors, 1)

		local ev = fibers.perform(rx:recv_op())
		assert_eq(ev.kind, 'wire_error')
		assert_match(ev.err, '^decode_failed')
		assert_match(ev.last_decode_error, '^decode_failed')
		assert_eq(ev.last_bad_line_len, #line)
		assert_eq(ev.last_bad_line_xxhash32, xxhash32.digest_hex(line))
		assert_eq(ev.last_bad_line_head, '[mem] boot\\r\\n{"type":"hello"')
		assert_eq(ev.last_bad_line_tail, '[mem] boot\\r\\n{"type":"hello"')
	end)
end

function tests.test_reader_ignores_blank_lines_from_hal_transport()
	fibers.run(function (scope)
		local tx, rx = mailbox.new(8, { full = 'reject_newest' })
		local hello = assert(protocol.encode_line(assert(protocol.hello_ack('peer-sid', 'mcu'))))
		local wrapped = assert(hal_transport.wrap_transport(raw_line_transport { '', ' \t\r', hello }))

		local result = io_mod.run_reader(scope, {
			read_frame_op = function () return wrapped:read_frame_op() end,
			downstream_tx = tx,
			bad_frame_limit = 1,
			bad_frame_window_s = 10,
		})

		assert_eq(result.role, 'reader')
		assert_eq(result.frames_read, 1)
		assert_eq(result.wire_errors, 0)

		local ev = fibers.perform(rx:recv_op())
		assert_eq(ev.kind, 'frame_received')
		assert_eq(ev.frame.type, 'hello_ack')
		assert_eq(ev.frame.sid, 'peer-sid')
	end)
end

function tests.test_reader_resyncs_short_non_printable_prefix_before_json()
	fibers.run(function (scope)
		local tx, rx = mailbox.new(8, { full = 'reject_newest' })
		local hello = assert(protocol.encode_line(assert(protocol.hello_ack('peer-sid', 'mcu'))))
		local line = string.char(0xfe) .. hello
		local wrapped = assert(hal_transport.wrap_transport(raw_line_transport {
			line,
		}))

		local result = io_mod.run_reader(scope, {
			read_frame_op = function () return wrapped:read_frame_op() end,
			downstream_tx = tx,
			bad_frame_limit = 1,
			bad_frame_window_s = 10,
		})

		assert_eq(result.role, 'reader')
		assert_eq(result.frames_read, 1)
		assert_eq(result.wire_errors, 0)

		local ev = fibers.perform(rx:recv_op())
		assert_eq(ev.kind, 'frame_received')
		assert_eq(ev.frame.type, 'hello_ack')
		assert_eq(ev.frame.sid, 'peer-sid')
		assert_eq(ev.line_resync, true)
		assert_eq(ev.last_line_resync_prefix_len, 1)
		assert_eq(ev.last_line_resync_line_len, #line)
		assert_eq(ev.last_line_resync_xxhash32, xxhash32.digest_hex(line))
		assert_eq(ev.last_line_resync_type, 'hello_ack')
		assert_eq(ev.last_line_resync_peer_sid, 'peer-sid')
	end)
end

function tests.test_reader_resyncs_long_non_printable_prefix_before_json()
	fibers.run(function (scope)
		local tx, rx = mailbox.new(8, { full = 'reject_newest' })
		local hello = assert(protocol.encode_line(assert(protocol.hello_ack('peer-sid-long', 'mcu'))))
		local prefix = string.rep(string.char(0), 1592)
		local line = prefix .. hello
		local wrapped = assert(hal_transport.wrap_transport(raw_line_transport { line }))

		local result = io_mod.run_reader(scope, {
			read_frame_op = function () return wrapped:read_frame_op() end,
			downstream_tx = tx,
			bad_frame_limit = 1,
			bad_frame_window_s = 10,
		})

		assert_eq(result.role, 'reader')
		assert_eq(result.frames_read, 1)
		assert_eq(result.wire_errors, 0)

		local ev = fibers.perform(rx:recv_op())
		assert_eq(ev.kind, 'frame_received')
		assert_eq(ev.frame.type, 'hello_ack')
		assert_eq(ev.frame.sid, 'peer-sid-long')
		assert_eq(ev.line_resync, true)
		assert_eq(ev.last_line_resync_prefix_len, #prefix)
		assert_eq(ev.last_line_resync_line_len, #line)
		assert_eq(ev.last_line_resync_xxhash32, xxhash32.digest_hex(line))
		assert_eq(ev.last_line_resync_type, 'hello_ack')
		assert_eq(ev.last_line_resync_peer_sid, 'peer-sid-long')
	end)
end

function tests.test_reader_resync_rejects_printable_prefix_before_json()
	fibers.run(function (scope)
		local tx, rx = mailbox.new(8, { full = 'reject_newest' })
		local hello = assert(protocol.encode_line(assert(protocol.hello_ack('peer-sid', 'mcu'))))
		local line = '[mem] boot ' .. hello
		local wrapped = assert(hal_transport.wrap_transport(raw_line_transport { line }))

		local result = io_mod.run_reader(scope, {
			read_frame_op = function () return wrapped:read_frame_op() end,
			downstream_tx = tx,
			bad_frame_limit = 2,
			bad_frame_window_s = 10,
		})

		assert_eq(result.role, 'reader')
		assert_eq(result.frames_read, 0)
		assert_eq(result.wire_errors, 1)

		local ev = fibers.perform(rx:recv_op())
		assert_eq(ev.kind, 'wire_error')
		assert_match(ev.err, '^decode_failed')
		assert_nil(ev.line_resync)
		assert_eq(ev.last_bad_line_len, #line)
	end)
end

function tests.test_reader_resync_rejects_prefix_beyond_scan_window()
	fibers.run(function (scope)
		local tx, rx = mailbox.new(8, { full = 'reject_newest' })
		local hello = assert(protocol.encode_line(assert(protocol.hello_ack('peer-sid', 'mcu'))))
		local prefix = string.rep(string.char(0), 4096)
		local line = prefix .. hello
		local wrapped = assert(hal_transport.wrap_transport(raw_line_transport { line }))

		local result = io_mod.run_reader(scope, {
			read_frame_op = function () return wrapped:read_frame_op() end,
			downstream_tx = tx,
			bad_frame_limit = 2,
			bad_frame_window_s = 10,
		})

		assert_eq(result.role, 'reader')
		assert_eq(result.frames_read, 0)
		assert_eq(result.wire_errors, 1)

		local ev = fibers.perform(rx:recv_op())
		assert_eq(ev.kind, 'wire_error')
		assert_match(ev.err, '^decode_failed')
		assert_nil(ev.line_resync)
		assert_eq(ev.last_bad_line_len, #line)
	end)
end

function tests.test_reader_resync_metadata_includes_xfer_id()
	fibers.run(function (scope)
		local tx, rx = mailbox.new(8, { full = 'reject_newest' })
		local frame = {
			type = 'xfer_ready',
			xfer_id = 'xfer-resync',
		}
		local line = string.char(1, 2, 3) .. assert(protocol.encode_line(frame))
		local wrapped = assert(hal_transport.wrap_transport(raw_line_transport { line }))

		local result = io_mod.run_reader(scope, {
			read_frame_op = function () return wrapped:read_frame_op() end,
			downstream_tx = tx,
			bad_frame_limit = 1,
			bad_frame_window_s = 10,
		})

		assert_eq(result.role, 'reader')
		assert_eq(result.frames_read, 1)
		assert_eq(result.wire_errors, 0)

		local ev = fibers.perform(rx:recv_op())
		assert_eq(ev.kind, 'frame_received')
		assert_eq(ev.frame.type, 'xfer_ready')
		assert_eq(ev.frame.xfer_id, 'xfer-resync')
		assert_eq(ev.last_line_resync_prefix_len, 3)
		assert_eq(ev.last_line_resync_type, 'xfer_ready')
		assert_eq(ev.last_line_resync_xfer_id, 'xfer-resync')
	end)
end

function tests.test_reader_recovery_includes_last_bad_line_diagnostics()
	fibers.run(function (scope)
		local tx, rx = mailbox.new(8, { full = 'reject_newest' })
		local first = '[value] first'
		local second = '{"type":"hello"}{"type":"hello_ack"}'
		local wrapped = assert(hal_transport.wrap_transport(raw_line_transport { first, second }))

		local result = io_mod.run_reader(scope, {
			read_frame_op = function () return wrapped:read_frame_op() end,
			downstream_tx = tx,
			bad_frame_limit = 2,
			bad_frame_window_s = 10,
			bad_frame_quiet_s = 0.01,
		})

		assert_eq(result.role, 'reader')
		assert_eq(result.wire_errors, 2)

		local ev1 = fibers.perform(rx:recv_op())
		local ev2 = fibers.perform(rx:recv_op())
		assert_eq(ev1.kind, 'wire_error')
		assert_eq(ev2.kind, 'wire_recovery')
		assert_eq(ev2.reason, 'bad_frame_limit')
		assert_match(ev2.last_decode_error, '^decode_failed')
		assert_eq(ev2.last_bad_line_len, #second)
		assert_eq(ev2.last_bad_line_xxhash32, xxhash32.digest_hex(second))
		assert_eq(ev2.last_bad_line_head, second)
		assert_eq(ev2.last_bad_line_tail, second)
	end)
end

function tests.test_reader_coalesces_deadline_drains_until_quiet()
	local logs = capture_prints(function ()
		fibers.run(function (scope)
			local tx, rx = mailbox.new(8, { full = 'reject_newest' })
			local gate = { drain_active = false, hello_quiet_until = 0 }
			local drain_calls = 0
			local quiet_seen
			local drain_results = {
				{ bytes = 9, reads = 1, reason = 'deadline' },
				{ bytes = 8, reads = 1, reason = 'deadline' },
				{ bytes = 3, reads = 1, reason = 'quiet' },
			}

				local result = io_mod.run_reader(scope, {
					read_frame_op = read_results {
						{ err = 'decode_failed: first' },
						{ err = 'decode_failed: second' },
					},
					downstream_tx = tx,
					recovery_gate = gate,
					trace_io = true,
					bad_frame_limit = 2,
					bad_frame_window_s = 10,
					bad_frame_quiet_s = 0.20,
				drain_input_op = function ()
					return op.guard(function ()
						drain_calls = drain_calls + 1
						assert_true(gate.drain_active, 'reader must keep drain_active throughout recovery')
						assert_true(gate.hello_quiet_until > fibers.now(), 'reader must set hello quiet before draining')
						quiet_seen = gate.hello_quiet_until
						return op.always(drain_results[drain_calls], nil)
					end)
				end,
			})

			assert_eq(result.role, 'reader')
			assert_eq(result.wire_errors, 2)
			assert_eq(drain_calls, 3)
			assert_eq(gate.drain_active, false)
			assert_eq(gate.hello_quiet_until, quiet_seen)

			local ev1 = fibers.perform(rx:recv_op())
			local ev2 = fibers.perform(rx:recv_op())
			assert_eq(ev1.kind, 'wire_error')
			assert_eq(ev2.kind, 'wire_recovery')
			assert_eq(ev2.reason, 'bad_frame_limit')
			assert_eq(ev2.wire_errors, 2)
			assert_eq(ev2.bad_frame_count, 2)
			assert_eq(ev2.drained_bytes, 20)
			assert_eq(ev2.drain_attempts, 3)
			assert_eq(ev2.drain_reason, 'quiet')
			assert_eq(ev2.quiet_until, quiet_seen)
		end)
	end)

	assert_eq(#logs, 1)
	assert_match(logs[1], 'reader_wire_recovery')
	assert_match(logs[1], 'drain_attempts')
	assert_match(logs[1], '3')
end

function tests.test_reader_recovery_window_expires_after_repeated_deadlines()
	fibers.run(function (scope)
		local tx, rx = mailbox.new(8, { full = 'reject_newest' })
		local gate = { drain_active = false, hello_quiet_until = 0 }
		local drain_calls = 0

		local result = io_mod.run_reader(scope, {
			read_frame_op = read_results {
				{ err = 'decode_failed: first' },
				{ err = 'decode_failed: second' },
			},
			downstream_tx = tx,
			recovery_gate = gate,
			bad_frame_limit = 2,
			bad_frame_window_s = 10,
			bad_frame_quiet_s = 0.035,
			drain_input_op = function ()
				return op.guard(function ()
					drain_calls = drain_calls + 1
					assert_true(gate.drain_active, 'reader must keep drain_active throughout recovery')
					return sleep.sleep_op(0.020):wrap(function ()
						return { bytes = 1, reads = 1, reason = 'deadline' }, nil
					end)
				end)
			end,
		})

		assert_eq(result.role, 'reader')
		assert_eq(result.wire_errors, 2)
		assert_eq(drain_calls, 2)
		assert_eq(gate.drain_active, false)

		local ev1 = fibers.perform(rx:recv_op())
		local ev2 = fibers.perform(rx:recv_op())
		assert_eq(ev1.kind, 'wire_error')
		assert_eq(ev2.kind, 'wire_recovery')
		assert_eq(ev2.drain_attempts, 2)
		assert_eq(ev2.drained_bytes, 2)
		assert_eq(ev2.drain_reason, 'recovery_window_expired')
	end)
end

function tests.test_reader_recovery_cancellation_clears_gate_and_propagates()
	fibers.run(function (root_scope)
		local tx, rx = mailbox.new(8, { full = 'reject_newest' })
		local entered_tx, entered_rx = mailbox.new(1, { full = 'reject_newest' })
		local gate = { drain_active = false, hello_quiet_until = 0 }
		local child = assert(root_scope:child())

		local ok, err = child:spawn(function (scope)
			io_mod.run_reader(scope, {
				read_frame_op = read_results {
					{ err = 'decode_failed: first' },
				},
				downstream_tx = tx,
				recovery_gate = gate,
				bad_frame_limit = 1,
				bad_frame_window_s = 10,
				bad_frame_quiet_s = 1.0,
				drain_input_op = function ()
					return op.guard(function ()
						queue.try_admit_required(entered_tx, true, 'drain_entered')
						assert_true(gate.drain_active, 'reader must set drain_active before draining')
						return op.never()
					end)
				end,
			})
		end)
		assert_true(ok, err)

		assert_true(fibers.perform(entered_rx:recv_op()))
		assert_eq(gate.drain_active, true)
		child:cancel('cancelled_for_test')

		local st, _, primary = fibers.perform(child:join_op())
		assert_eq(st, 'cancelled')
		assert_eq(primary, 'cancelled_for_test')
		assert_eq(gate.drain_active, false)

		local ev, recv_err = queue.try_recv_now(rx)
		assert_nil(ev)
		assert_eq(recv_err, 'not_ready')
	end)
end

function tests.test_reader_recovery_downstream_close_and_reject_clear_gate()
	fibers.run(function (scope)
		local tx = mailbox.new(1, { full = 'reject_newest' })
		local gate = { drain_active = false, hello_quiet_until = 0 }
		tx:close('downstream_done')

		local result = io_mod.run_reader(scope, {
			read_frame_op = read_results {
				{ err = 'decode_failed: first' },
			},
			downstream_tx = tx,
			recovery_gate = gate,
			bad_frame_limit = 1,
			bad_frame_window_s = 10,
			bad_frame_quiet_s = 0.05,
			drain_input_op = function ()
				return op.always({ bytes = 0, reads = 0, reason = 'quiet' }, nil)
			end,
		})

		assert_eq(result.reason, 'downstream_done')
		assert_eq(gate.drain_active, false)
	end)

	fibers.run(function ()
		local tx = mailbox.new(0, { full = 'reject_newest' })
		local gate = { drain_active = false, hello_quiet_until = 0 }

		local st, _, primary = fibers.run_scope(function (scope)
			io_mod.run_reader(scope, {
				read_frame_op = read_results {
					{ err = 'decode_failed: first' },
				},
				downstream_tx = tx,
				recovery_gate = gate,
				bad_frame_limit = 1,
				bad_frame_window_s = 10,
				bad_frame_quiet_s = 0.05,
				drain_input_op = function ()
					return op.always({ bytes = 0, reads = 0, reason = 'quiet' }, nil)
				end,
			})
		end)

		assert_eq(st, 'failed')
		assert_match(primary, 'reader downstream rejected wire event')
		assert_eq(gate.drain_active, false)
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

function tests.test_lane_writer_pauses_writes_while_recovery_drain_is_active()
	fibers.run(function (scope)
		local rpc_tx, rpc_rx = mailbox.new(8, { full = 'reject_newest' })
		local done_tx, done_rx = mailbox.new(1, { full = 'reject_newest' })
		local gate = { drain_active = true, hello_quiet_until = 0 }
		local written = {}

		send_frame(rpc_tx, 'rpc-frame', 'rpc_frame')
		rpc_tx:close('rpc_done')

		assert_true(scope:spawn(function ()
			local result = io_mod.run_lane_writer(scope, {
				control_rx = closed_rx('control_done'),
				rpc_rx = rpc_rx,
				bulk_rx = closed_rx('bulk_done'),
				recovery_gate = gate,
				write_frame_op = function (frame)
					return op.guard(function ()
						written[#written + 1] = frame
						return op.always(true, nil)
					end)
				end,
			})
			queue.try_admit_required(done_tx, result, 'writer_done')
		end))

		fibers.perform(sleep.sleep_op(0.03))
		assert_eq(#written, 0)
		gate.drain_active = false

		local result = fibers.perform(done_rx:recv_op())
		assert_eq(result.frames_written, 1)
		assert_eq(written[1], 'rpc-frame')
	end)
end

function tests.test_lane_writer_drops_queued_frames_from_stale_session()
	fibers.run(function (scope)
		local rpc_tx, rpc_rx = mailbox.new(8, { full = 'reject_newest' })
		local written = {}
		local session_gate = {
			current_session = {
				link_id = 'link-a',
				link_generation = 1,
				session_generation = 2,
				peer_sid = 'new-peer',
			},
			drop_reason = 'peer_sid_changed',
		}

		queue.try_admit_required(rpc_tx, {
			kind = 'send_frame',
			frame = 'stale-frame',
			session = {
				link_id = 'link-a',
				link_generation = 1,
				session_generation = 1,
				peer_sid = 'old-peer',
			},
		}, 'stale_frame')
		queue.try_admit_required(rpc_tx, {
			kind = 'send_frame',
			frame = 'current-frame',
			session = {
				link_id = 'link-a',
				link_generation = 1,
				session_generation = 2,
				peer_sid = 'new-peer',
			},
		}, 'current_frame')
		rpc_tx:close('rpc_done')

		local result = io_mod.run_lane_writer(scope, {
			control_rx = closed_rx('control_done'),
			rpc_rx = rpc_rx,
			bulk_rx = closed_rx('bulk_done'),
			session_gate = session_gate,
			write_frame_op = function (frame)
				return op.guard(function ()
					written[#written + 1] = frame
					return op.always(true, nil)
				end)
			end,
		})

		assert_eq(result.frames_written, 1)
		assert_eq(written[1], 'current-frame')
	end)
end

function tests.test_lane_writer_delays_hello_until_recovery_quiet_expires()
	fibers.run(function (scope)
		local control_tx, control_rx = mailbox.new(8, { full = 'reject_newest' })
		local done_tx, done_rx = mailbox.new(1, { full = 'reject_newest' })
		local gate = { drain_active = false, hello_quiet_until = fibers.now() + 0.06 }
		local written = {}

		send_frame(control_tx, { type = 'hello' }, 'hello_frame')
		control_tx:close('control_done')

		assert_true(scope:spawn(function ()
			local result = io_mod.run_lane_writer(scope, {
				control_rx = control_rx,
				rpc_rx = closed_rx('rpc_done'),
				bulk_rx = closed_rx('bulk_done'),
				recovery_gate = gate,
				write_frame_op = function (frame)
					return op.guard(function ()
						written[#written + 1] = frame
						return op.always(true, nil)
					end)
				end,
			})
			queue.try_admit_required(done_tx, result, 'writer_done')
		end))

		fibers.perform(sleep.sleep_op(0.02))
		assert_eq(#written, 0)

		local result = fibers.perform(done_rx:recv_op())
		assert_eq(result.frames_written, 1)
		assert_eq(written[1].type, 'hello')
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
