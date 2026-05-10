-- services/fabric/io.lua
--
-- Fabric frame reader and lane writer owners.
--
-- I/O owns only:
--   * reading already-decoded Fabric frames from a transport/HAL adapter
--   * writing already-validated Fabric frames to a transport/HAL adapter
--   * writer-lane selection for control/rpc/bulk outbound queues
--
-- Transport wrapping, JSONL line handling, HAL opening, and compatibility
-- adaptation belong outside this module.

local fibers         = require 'fibers'
local op             = require 'fibers.op'
local protocol       = require 'services.fabric.protocol'
local queue          = require 'devicecode.support.queue'
local priority_event = require 'devicecode.support.priority_event'
local contracts      = require 'devicecode.support.contracts'
local validate       = require 'shared.validate'

local M = {}

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

local function clean_read_end(frame, err)
	return frame == nil and (err == nil or err == 'eof' or err == 'closed')
end

local function reader_result(frames_read, wire_errors, reason)
	return {
		role        = 'reader',
		frames_read = frames_read,
		wire_errors = wire_errors,
		reason      = reason,
	}
end

local function frame_event(frame)
	return {
		kind  = 'frame_received',
		frame = frame,
	}
end

local function wire_error_event(err)
	return {
		kind = 'wire_error',
		err  = err,
		at   = fibers.now(),
	}
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

--------------------------------------------------------------------------------
-- Reader owner
--------------------------------------------------------------------------------

function M.run_reader(scope, params)
	require_table(scope, 'fabric.io.run_reader: scope', 2)
	params = require_table(params, 'fabric.io.run_reader: params table', 2)

	local read_frame_op = require_function(params.read_frame_op, 'run_reader: read_frame_op', 2)
	local downstream_tx = require_tx(params.downstream_tx, 'run_reader: downstream_tx', 2)

	local frames_read = 0
	local wire_errors = 0

	while true do
		local frame, read_err = fibers.perform(read_frame_op())

		if clean_read_end(frame, read_err) then
			return reader_result(frames_read, wire_errors, read_err or 'eof')
		end

		local ev
		local label

		if frame ~= nil then
			ev = frame_event(frame)
			label = 'frame'

		elseif protocol.is_wire_protocol_error
			and protocol.is_wire_protocol_error(read_err)
		then
			ev = wire_error_event(read_err)
			label = 'wire error'

		else
			error('reader read failed: ' .. tostring(read_err or 'unknown'), 0)
		end

		local ok, send_err = perform_send(downstream_tx, ev)

		if ok == true then
			if frame ~= nil then
				frames_read = frames_read + 1
			else
				wire_errors = wire_errors + 1
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

function M.run_lane_writer(scope, params)
	require_table(scope, 'fabric.io.run_lane_writer: scope', 2)
	params = require_table(params, 'fabric.io.run_lane_writer: params table', 2)

	local write_frame_op = require_function(params.write_frame_op, 'run_lane_writer: write_frame_op', 2)

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

			local ok, err = perform_write(write_frame_op, frame)
			if ok ~= true then
				error('writer write failed: ' .. tostring(err), 0)
			end

			written = written + 1
			by_lane[lane] = (by_lane[lane] or 0) + 1
			commit_turn(state, lane)

			if flush_each then
				local flushed, flush_err = perform_flush(flush_op)
				if flushed ~= true then
					error('writer flush failed: ' .. tostring(flush_err), 0)
				end
			end
		end
	end

	local flushed, flush_err = perform_flush(flush_op)
	if flushed ~= true then
		error('writer flush failed: ' .. tostring(flush_err), 0)
	end

	return {
		role           = 'writer',
		frames_written = written,
		reason         = 'closed',
		lanes          = lane_counts(by_lane),
	}
end

return M
