-- services/fabric/io.lua
--
-- Fabric frame reader and lane writer owners.
--
-- I/O owns only:
--   * reading already-decoded Fabric frames from a transport/HAL adapter
--   * writing already-validated Fabric frames to a transport/HAL adapter
--   * writer-lane selection for control/rpc/bulk outbound queues
--
-- Transport wrapping, JSONL line handling and HAL opening belong outside
-- this module.

local fibers         = require 'fibers'
local fiber_scope    = require 'fibers.scope'
local op             = require 'fibers.op'
local sleep          = require 'fibers.sleep'
local protocol       = require 'services.fabric.protocol'
local queue          = require 'devicecode.support.queue'
local priority_event = require 'devicecode.support.priority_event'
local contracts      = require 'devicecode.support.contracts'
local validate       = require 'shared.validate'

local M = {}

local DEFAULT_BAD_FRAME_LIMIT = 5
local DEFAULT_BAD_FRAME_WINDOW_S = 10.0
local DEFAULT_BAD_FRAME_QUIET_S = 2.0
local DRAIN_SLICE_MAX_S = 0.100
local DRAIN_SLICE_QUIET_S = 0.020
local DRAIN_SLICE_READ_S = 0.010
local DRAIN_SLICE_MAX_BYTES = 64 * 1024

--------------------------------------------------------------------------------
-- Checks and small helpers
--------------------------------------------------------------------------------

local function require_table(v, name, level)
	return validate.table(v, name, (level or 1) + 1)
end

local function require_function(v, name, level)
	return validate.function_(v, name, (level or 1) + 1)
end

local function require_rx(v, name, level)
	return contracts.require_rx(v, name, (level or 1) + 1)
end

local function require_tx(v, name, level)
	return contracts.require_tx(v, name, (level or 1) + 1)
end

local function reason_of(rx_or_tx, fallback)
	if type(rx_or_tx) == 'table' and type(rx_or_tx.why) == 'function' then
		return rx_or_tx:why() or fallback
	end
	return fallback
end

local function perform_send(tx, value)
	local ok, err = fibers.perform(tx:send_op(value))

	if ok == true then return true, nil end
	if ok == false then return false, err or 'full' end

	return nil, reason_of(tx, err or 'closed')
end

local function perform_write(write_frame_op, frame)
	local ok, err = fibers.perform(write_frame_op(frame))
	if ok == true then return true, nil end
	return nil, err or 'write_failed'
end

local function perform_flush(flush_op)
	if flush_op == nil then return true, nil end

	local ok, err = fibers.perform(flush_op())
	if ok == true then return true, nil end
	return nil, err or 'flush_failed'
end

local function positive_int(v, fallback, name)
	if v == nil then return fallback end
	if type(v) ~= 'number' or v <= 0 or v % 1 ~= 0 then
		error(name .. ' must be a positive integer', 3)
	end
	return v
end

local function positive_number(v, fallback, name)
	if v == nil then return fallback end
	if type(v) ~= 'number' or v <= 0 or v ~= v or v == math.huge or v == -math.huge then
		error(name .. ' must be a positive finite number', 3)
	end
	return v
end

local function clean_read_end(frame, err)
	return frame == nil and (err == nil or err == 'eof' or err == 'closed')
end

local BAD_LINE_FIELDS = {
	'last_decode_error',
	'last_bad_line_len',
	'last_bad_line_xxhash32',
	'last_bad_line_head',
	'last_bad_line_tail',
}

local RESYNC_FIELDS = {
	'line_resync',
	'last_line_resync_prefix_len',
	'last_line_resync_line_len',
	'last_line_resync_xxhash32',
	'last_line_resync_type',
	'last_line_resync_peer_sid',
	'last_line_resync_xfer_id',
}

local function wire_error_string(err)
	if type(err) == 'table' then
		return tostring(err.err or err.reason or err.last_decode_error or 'wire_error')
	end
	return tostring(err or 'wire_error')
end

local function copy_bad_line_fields(dst, src)
	if type(dst) ~= 'table' or type(src) ~= 'table' then return dst end
	for _, k in ipairs(BAD_LINE_FIELDS) do
		if src[k] ~= nil then dst[k] = src[k] end
	end
	return dst
end

local function copy_resync_fields(dst, src)
	if type(dst) ~= 'table' or type(src) ~= 'table' then return dst end
	for _, k in ipairs(RESYNC_FIELDS) do
		if src[k] ~= nil then dst[k] = src[k] end
	end
	return dst
end

local function reader_result(frames_read, wire_errors, reason)
	return {
		role        = 'reader',
		frames_read = frames_read,
		wire_errors = wire_errors,
		reason      = reason,
	}
end

local function frame_event(frame, diag)
	return copy_resync_fields({
		kind  = 'frame_received',
		frame = frame,
	}, diag)
end

local function wire_error_event(err, wire_errors, bad_frame_count)
	return copy_bad_line_fields({
		kind = 'wire_error',
		err  = wire_error_string(err),
		at   = fibers.now(),
		wire_errors = wire_errors,
		bad_frame_count = bad_frame_count,
	}, err)
end

local function wire_recovery_event(reason, wire_errors, bad_frame_count, drain_result, drain_err, quiet_until, bad_line_diag)
	drain_result = drain_result or {}
	return copy_bad_line_fields({
		kind = 'wire_recovery',
		reason = reason or 'bad_frame_limit',
		err = reason or 'bad_frame_limit',
		at = fibers.now(),
		wire_errors = wire_errors,
		bad_frame_count = bad_frame_count,
		drained_bytes = drain_result.bytes or 0,
		drain_attempts = drain_result.drain_attempts or 0,
		drain_reason = drain_result.reason,
		drain_err = drain_err,
		quiet_until = quiet_until,
	}, bad_line_diag)
end

local function send_item_frame(item)
	if type(item) ~= 'table' or item.kind ~= 'send_frame' then
		error('writer expected send_frame item', 0)
	end

	local frame = item.frame
	if frame == nil then
		error('writer send_frame item has nil frame', 0)
	end

	return frame
end

local function same_session(a, b)
	return type(a) == 'table'
		and type(b) == 'table'
		and a.link_id == b.link_id
		and a.link_generation == b.link_generation
		and a.session_generation == b.session_generation
		and a.peer_sid == b.peer_sid
end

local function send_item_matches_session_gate(gate, item)
	if type(gate) ~= 'table' then return true end
	if type(item) ~= 'table' or item.session == nil then return true end
	return same_session(gate.current_session, item.session)
end

local function log_io(enabled, event, fields)
	if enabled ~= true then return end
	local parts = { '[fabric-io]', tostring(event) }
	for k, v in pairs(fields or {}) do
		if v ~= nil then
			parts[#parts + 1] = tostring(k)
			parts[#parts + 1] = tostring(v)
		end
	end
	print(table.concat(parts, ' '))
end

local function frame_fields(frame)
	if type(frame) ~= 'table' then
		return { type = type(frame) }
	end
	local out = {
		type = frame.type,
		id = frame.xfer_id or frame.sid,
		offset = frame.offset,
		next = frame.next,
		size = frame.size,
		err = frame.err,
	}
	if frame.type == 'xfer_chunk' and type(frame.data) == 'string' then
		out.raw_len = #frame.data
		out.chunk_digest = frame.chunk_digest
	end
	return out
end

local function record_bad_frame(times, at, window_s)
	local kept = {}
	local cutoff = at - window_s
	for _, seen_at in ipairs(times or {}) do
		if seen_at >= cutoff then
			kept[#kept + 1] = seen_at
		end
	end
	kept[#kept + 1] = at
	return kept, #kept
end

local function max_time(a, b)
	a = tonumber(a) or 0
	b = tonumber(b) or 0
	if a > b then return a end
	return b
end

local function set_recovery_gate(gate, drain_active, quiet_until)
	if type(gate) ~= 'table' then return end
	gate.drain_active = drain_active == true
	if quiet_until ~= nil then
		gate.hello_quiet_until = max_time(gate.hello_quiet_until, quiet_until)
	end
end

local function perform_drain(drain_input_op, opts)
	if type(drain_input_op) ~= 'function' then
		return { bytes = 0, reads = 0, reason = 'drain_unsupported' }, 'drain_unsupported'
	end
	opts = opts or {}
	local ok, result, err = pcall(function ()
		return fibers.perform(drain_input_op({
			max_bytes = opts.max_bytes or DRAIN_SLICE_MAX_BYTES,
			total_s = opts.total_s or DRAIN_SLICE_MAX_S,
			quiet_s = opts.quiet_s or DRAIN_SLICE_QUIET_S,
			read_s = opts.read_s or DRAIN_SLICE_READ_S,
		}))
	end)
	if not ok then
		if fiber_scope.is_cancelled(result) then
			error(result, 0)
		end
		return { bytes = 0, reads = 0, reason = 'failed' }, tostring(result or 'drain_failed')
	end
	if result == nil then
		return { bytes = 0, reads = 0, reason = err or 'drain_failed' }, err or 'drain_failed'
	end
	return result, err
end

local function recovery_fields(ev)
	return copy_bad_line_fields({
		reason = ev.reason,
		wire_errors = ev.wire_errors,
		bad_frame_count = ev.bad_frame_count,
		drained_bytes = ev.drained_bytes,
		drain_attempts = ev.drain_attempts,
		drain_err = ev.drain_err,
		drain_reason = ev.drain_reason,
		quiet_until = ev.quiet_until,
	}, ev)
end

local function should_continue_drain(reason, drain_err)
	if drain_err ~= nil then return false end
	return reason == 'deadline' or reason == 'max_bytes'
end

local function drain_slice_opts(quiet_until)
	local remaining = quiet_until - fibers.now()
	if remaining <= 0 then return nil end
	local total_s = remaining
	if total_s > DRAIN_SLICE_MAX_S then
		total_s = DRAIN_SLICE_MAX_S
	end
	return {
		max_bytes = DRAIN_SLICE_MAX_BYTES,
		total_s = total_s,
		quiet_s = DRAIN_SLICE_QUIET_S,
		read_s = DRAIN_SLICE_READ_S,
	}
end

local function run_recovery_window(scope, downstream_tx, recovery_gate, drain_input_op, params)
	require_table(scope, 'fabric.io.run_recovery_window: scope', 2)
	params = params or {}

	local quiet_until = fibers.now() + params.bad_frame_quiet_s
	local aggregate = {
		bytes = 0,
		reads = 0,
		reason = 'drain_not_started',
		drain_attempts = 0,
	}
	local drain_err

	set_recovery_gate(recovery_gate, true, quiet_until)

	local ok, send_ok, send_err = pcall(function ()
		while true do
			local slice_opts = drain_slice_opts(quiet_until)
			if slice_opts == nil then
				aggregate.reason = 'recovery_window_expired'
				break
			end

			local drain_result, err = perform_drain(drain_input_op, slice_opts)
			drain_result = drain_result or {}
			aggregate.drain_attempts = aggregate.drain_attempts + 1
			aggregate.bytes = aggregate.bytes + (tonumber(drain_result.bytes) or 0)
			aggregate.reads = aggregate.reads + (tonumber(drain_result.reads) or 0)
			aggregate.reason = drain_result.reason or err or 'drain_failed'
			drain_err = err

			if not should_continue_drain(aggregate.reason, drain_err) then
				break
			end

			if fibers.now() >= quiet_until then
				aggregate.reason = 'recovery_window_expired'
				break
			end
		end

		local ev = wire_recovery_event(
			params.reason or 'bad_frame_limit',
			params.wire_errors,
			params.bad_frame_count,
			aggregate,
			drain_err,
			quiet_until,
			params.bad_line_diag
		)
		log_io(params.trace_io == true, 'reader_wire_recovery', recovery_fields(ev))
		return perform_send(downstream_tx, ev)
	end)

	set_recovery_gate(recovery_gate, false, quiet_until)

	if not ok then
		if fiber_scope.is_cancelled(send_ok) then
			error(send_ok, 0)
		end
		error(send_ok, 0)
	end

	return send_ok, send_err
end

--------------------------------------------------------------------------------
-- Reader owner
--------------------------------------------------------------------------------

function M.run_reader(scope, params)
	require_table(scope, 'fabric.io.run_reader: scope', 2)
	params = require_table(params, 'fabric.io.run_reader: params table', 2)

	local read_frame_op = require_function(params.read_frame_op, 'run_reader: read_frame_op', 2)
	local downstream_tx = require_tx(params.downstream_tx, 'run_reader: downstream_tx', 2)
	local drain_input_op = params.drain_input_op
	if drain_input_op ~= nil then
		require_function(drain_input_op, 'run_reader: drain_input_op', 2)
	end
	local recovery_gate = params.recovery_gate
	local trace_io = params.trace_io == true
	local bad_frame_limit = positive_int(
		params.bad_frame_limit,
		DEFAULT_BAD_FRAME_LIMIT,
		'run_reader: bad_frame_limit'
	)
	local bad_frame_window_s = positive_number(
		params.bad_frame_window_s,
		DEFAULT_BAD_FRAME_WINDOW_S,
		'run_reader: bad_frame_window_s'
	)
	local bad_frame_quiet_s = positive_number(
		params.bad_frame_quiet_s,
		DEFAULT_BAD_FRAME_QUIET_S,
		'run_reader: bad_frame_quiet_s'
	)

	local frames_read = 0
	local wire_errors = 0
	local bad_frame_times = {}

	while true do
		local frame, read_err, read_diag = fibers.perform(read_frame_op())

		if clean_read_end(frame, read_err) then
			return reader_result(frames_read, wire_errors, read_err or 'eof')
		end

		local ev
		local label
		local sent_by_recovery = false

		if frame ~= nil then
			ev = frame_event(frame, read_diag)
			label = 'frame'

		elseif protocol.is_wire_protocol_error
			and protocol.is_wire_protocol_error(read_err)
		then
			wire_errors = wire_errors + 1
			local at = fibers.now()
			local count
			bad_frame_times, count = record_bad_frame(bad_frame_times, at, bad_frame_window_s)
			if count >= bad_frame_limit then
				local ok, send_err = run_recovery_window(
					scope,
					downstream_tx,
					recovery_gate,
					drain_input_op,
					{
						reason = 'bad_frame_limit',
						wire_errors = wire_errors,
						bad_frame_count = count,
						bad_frame_quiet_s = bad_frame_quiet_s,
						trace_io = trace_io,
						bad_line_diag = read_err,
					}
				)
				sent_by_recovery = true
				bad_frame_times = {}
				if ok == nil then
					return reader_result(frames_read, wire_errors, send_err or 'downstream_closed')
				elseif ok ~= true then
					error('reader downstream rejected wire event: ' .. tostring(send_err or 'full'), 0)
				end
			else
				ev = wire_error_event(read_err, wire_errors, count)
			end
			label = 'wire event'

		else
			error('reader read failed: ' .. tostring(read_err or 'unknown'), 0)
		end

		if sent_by_recovery then
			ev = nil
		end

		local ok, send_err = true, nil
		if ev ~= nil then
			ok, send_err = perform_send(downstream_tx, ev)
		end

		if ok == true then
			if frame ~= nil then
				frames_read = frames_read + 1
			end

		elseif ok == nil then
			return reader_result(frames_read, wire_errors, send_err or 'downstream_closed')

		else
			error('reader downstream rejected ' .. label .. ': ' .. tostring(send_err or 'full'), 0)
		end
	end
end

--------------------------------------------------------------------------------
-- Lane-aware writer owner
--------------------------------------------------------------------------------

local ORDER_RPC  = { 'control', 'rpc',  'bulk' }
local ORDER_BULK = { 'control', 'bulk', 'rpc' }

local function lane_order(turn)
	if turn == 'bulk' then return ORDER_BULK end
	return ORDER_RPC
end

local function lane_counts(counts)
	return {
		control = counts.control or 0,
		rpc     = counts.rpc or 0,
		bulk    = counts.bulk or 0,
	}
end

local function mark_closed(state, lane, reason)
	if state.closed[lane] then return end
	state.closed[lane] = reason or 'closed'
	state.open = state.open - 1
end

local function receive_now(state)
	for _, lane in ipairs(lane_order(state.turn)) do
		if not state.closed[lane] then
			local pending = state.pending[lane]
			if pending ~= nil then
				state.pending[lane] = nil
				return lane, pending
			end

			local rx = state.rxs[lane]
			local item, err = queue.try_recv_now(rx)

			if item ~= nil then
				return lane, item
			end

			if err ~= 'not_ready' then
				mark_closed(state, lane, reason_of(rx, err or 'closed'))
			end
		end
	end

	return nil, nil
end

local function receive_blocking_op(state)
	return op.guard(function ()
		local arms = {}

		for lane, rx in pairs(state.rxs) do
			if not state.closed[lane] then
				arms[lane] = rx:recv_op():wrap(function (item)
					return lane, item
				end)
			end
		end

		if next(arms) == nil then
			return op.always(nil, nil)
		end

		return fibers.named_choice(arms):wrap(function (_, lane, item)
			return lane, item
		end)
	end)
end

local function commit_turn(state, lane)
	if lane == 'control' then return end

	if state.turn ~= lane then
		state.turn = lane
		state.quota_left = state.quotas[lane]
	end

	state.quota_left = state.quota_left - 1

	if state.quota_left <= 0 then
		state.turn = (lane == 'rpc') and 'bulk' or 'rpc'
		state.quota_left = state.quotas[state.turn]
	end
end

local function next_writer_item_op(state)
	return priority_event.next_op {
		label = 'fabric.io.lane_writer',
		allow_no_event = true,

		select_now = function ()
			local lane, item = receive_now(state)
			if lane == nil then return nil end
			return { lane = lane, item = item }
		end,

		wait_op = function ()
			return receive_blocking_op(state):wrap(function (lane, item)
				return { lane = lane, item = item }
			end)
		end,

		store_wake = function (wake)
			local lane = wake and wake.lane
			if lane == nil then return end

			if wake.item == nil then
				mark_closed(state, lane, reason_of(state.rxs[lane], 'closed'))
			else
				state.pending[lane] = wake.item
			end
		end,
	}
end

local function frame_is_hello(frame)
	return type(frame) == 'table' and frame.type == 'hello'
end

local function wait_for_recovery_gate_op(gate, frame)
	if type(gate) ~= 'table' then
		return op.always(true, nil)
	end

	return fibers.run_scope_op(function ()
		while true do
			local now = fibers.now()
			local quiet_until = tonumber(gate.hello_quiet_until) or 0
			local wait_s

			if gate.drain_active == true then
				wait_s = 0.020
			elseif frame_is_hello(frame) and quiet_until > now then
				wait_s = quiet_until - now
				if wait_s > 0.020 then wait_s = 0.020 end
			else
				return true, nil
			end

			fibers.perform(sleep.sleep_op(wait_s))
		end
	end):wrap(function (status, report, ok, err)
		if status ~= 'ok' then
			return nil, err or report or 'recovery_gate_wait_failed'
		end
		return ok, err
	end)
end

function M.run_lane_writer(scope, params)
	require_table(scope, 'fabric.io.run_lane_writer: scope', 2)
	params = require_table(params, 'fabric.io.run_lane_writer: params table', 2)

	local write_frame_op = require_function(params.write_frame_op, 'run_lane_writer: write_frame_op', 2)
	local trace_io = params.trace_io == true
	local recovery_gate = params.recovery_gate
	local session_gate = params.session_gate

	local flush_op = params.flush_op
	if flush_op ~= nil then
		require_function(flush_op, 'run_lane_writer: flush_op', 2)
	end

	local state = {
		rxs = {
			control = require_rx(params.control_rx, 'run_lane_writer: control_rx', 2),
			rpc     = require_rx(params.rpc_rx,     'run_lane_writer: rpc_rx', 2),
			bulk    = require_rx(params.bulk_rx,    'run_lane_writer: bulk_rx', 2),
		},

		closed     = {},
		open       = 3,
		turn       = params.initial_turn or 'rpc',
		pending    = {},
		quotas     = {
			rpc  = positive_int(params.rpc_quota,  4, 'run_lane_writer: rpc_quota'),
			bulk = positive_int(params.bulk_quota, 1, 'run_lane_writer: bulk_quota'),
		},
		quota_left = nil,
	}

	state.quota_left = state.quotas[state.turn] or state.quotas.rpc

	local flush_each = not not params.flush_each
	local written = 0
	local by_lane = { control = 0, rpc = 0, bulk = 0 }

	while state.open > 0 do
		local selected = fibers.perform(next_writer_item_op(state))

		if selected ~= nil and selected.item ~= nil then
			local lane = selected.lane
			local frame = send_item_frame(selected.item)
			if not send_item_matches_session_gate(session_gate, selected.item) then
				local f = frame_fields(frame)
				f.lane = lane
				f.reason = (type(session_gate) == 'table' and session_gate.drop_reason) or 'stale_session'
				log_io(trace_io, 'writer_stale_session_drop', f)
				commit_turn(state, lane)
			else
				fibers.perform(wait_for_recovery_gate_op(recovery_gate, frame))

				local f = frame_fields(frame)
				f.lane = lane
				log_io(trace_io, 'writer_tx_begin', f)

				local ok, err = perform_write(write_frame_op, frame)
				if ok ~= true then
					local fail_fields = frame_fields(frame)
					fail_fields.lane = lane
					fail_fields.err = err
					log_io(trace_io, 'writer_tx_failed', fail_fields)
					error('writer write failed: ' .. tostring(err), 0)
				end

				written = written + 1
				by_lane[lane] = (by_lane[lane] or 0) + 1
				local ok_fields = frame_fields(frame)
				ok_fields.lane = lane
				ok_fields.count = written
				log_io(trace_io, 'writer_tx_done', ok_fields)
				commit_turn(state, lane)

				if flush_each then
					local flush_fields = frame_fields(frame)
					flush_fields.lane = lane
					log_io(trace_io, 'writer_flush_begin', flush_fields)
					local flushed, flush_err = perform_flush(flush_op)
					if flushed ~= true then
						local fail_fields = frame_fields(frame)
						fail_fields.lane = lane
						fail_fields.err = flush_err
						log_io(trace_io, 'writer_flush_failed', fail_fields)
						error('writer flush failed: ' .. tostring(flush_err), 0)
					end
					local done_fields = frame_fields(frame)
					done_fields.lane = lane
					log_io(trace_io, 'writer_flush_done', done_fields)
				end
			end
		end
	end

	log_io(trace_io, 'writer_final_flush_begin', lane_counts(by_lane))
	local flushed, flush_err = perform_flush(flush_op)
	if flushed ~= true then
		log_io(trace_io, 'writer_final_flush_failed', { err = flush_err })
		error('writer flush failed: ' .. tostring(flush_err), 0)
	end
	log_io(trace_io, 'writer_final_flush_done', lane_counts(by_lane))

	return {
		role           = 'writer',
		frames_written = written,
		reason         = 'closed',
		lanes          = lane_counts(by_lane),
	}
end

return M
