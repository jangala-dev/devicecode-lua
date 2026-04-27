-- services/fabric/transfer_mgr.lua
--
-- Per-link transfer manager.
--
-- Responsibilities:
--   * own at most one active transfer per link
--   * transfer direction is part of the active transfer state
--   * reset the active transfer on session generation change
--   * publish retained transfer observability state:
--       state/fabric/link/<id>/transfer
--
-- Retained transfer state is for observability; protocol authority comes from
-- in-flight transfer control/data and the current session generation.
--
-- Design notes:
--   * one event loop arbitrates among:
--       - local transfer control requests
--       - inbound transfer frames
--       - session generation changes
--       - phase timeouts
--   * this module owns transfer protocol state only; file-backed artefacts and
--     durable storage remain behind HAL/host capabilities
--
-- Important:
--   * xfer_chunk.data is transported as encoded text on the wire
--   * transfer size/offset/checksum always refer to raw bytes

local fibers      = require 'fibers'
local runtime     = require 'fibers.runtime'
local sleep       = require 'fibers.sleep'
local uuid        = require 'uuid'

local blob_source = require 'shared.blob_source'
local protocol    = require 'services.fabric.protocol'
local statefmt    = require 'services.fabric.statefmt'

local perform = fibers.perform
local named_choice = fibers.named_choice

local M = {}

local function send_required(tx, value, what)
	local ok, reason = tx:send(value)
	if ok ~= true then
		error((what or 'mailbox_send_failed') .. ': ' .. tostring(reason or 'closed'), 0)
	end
end

local function send_frame(tx, class, frame)
	local item, err = protocol.writer_item(class, frame)
	if not item then error(err, 0) end
	send_required(tx, item, 'writer_queue_overflow')
end

local function reply_req(req, payload)
	if not req or req:done() then return end
	req:reply(payload)
end

local function fail_req(req, err)
	if not req or req:done() then return end
	req:fail(err)
end

local function send_abort(tx_control, xfer_id, err)
	send_frame(tx_control, 'control', {
		type = 'xfer_abort',
		xfer_id = xfer_id,
		err = err,
	})
end

-- Transfer shell event selection.
--
-- state contains:
--   * transfer_ctl_rx
--   * xfer_rx
--   * session / session_seen
--   * active :: active transfer record | nil
local function next_transfer_event_op(state)
	local ops = {
		ctl = state.transfer_ctl_rx:recv_op(),
		xfer = state.xfer_rx:recv_op(),
		session = state.session:changed_op(state.session_seen),
	}

	local deadline = math.huge
	if state.active and state.active.deadline < deadline then
		deadline = state.active.deadline
	end

	if deadline < math.huge then
		ops.timeout = sleep.sleep_until_op(deadline):wrap(function()
			return true
		end)
	end

	return named_choice(ops)
end

function M.run(ctx)
	local conn = assert(ctx.conn, 'transfer_mgr requires conn')
	local session = assert(ctx.session, 'transfer_mgr requires session')
	local xfer_rx = assert(ctx.xfer_rx, 'transfer_mgr requires xfer_rx')
	local tx_control = assert(ctx.tx_control, 'transfer_mgr requires tx_control')
	local tx_bulk = assert(ctx.tx_bulk, 'transfer_mgr requires tx_bulk')
	local transfer_ctl_rx = assert(ctx.transfer_ctl_rx, 'transfer_mgr requires transfer_ctl_rx')
	local link_id = assert(ctx.link_id, 'transfer_mgr requires link_id')
	local chunk_size = tonumber(ctx.chunk_size) or 2048
	local phase_timeout = tonumber(ctx.transfer_phase_timeout_s) or 15.0

	local transfer_topic = statefmt.component_topic(link_id, 'transfer')

	fibers.current_scope():finally(function()
		conn:unretain(transfer_topic)
	end)

	local active = nil
	local session_seen = session:pulse():version()
	local last_generation = session:get().generation

	local state = {
		session = session,
		xfer_rx = xfer_rx,
		transfer_ctl_rx = transfer_ctl_rx,
		session_seen = session_seen,
		active = active,
	}

	local function current_transfer_status()
		if not active then
			return { state = 'idle' }
		end

		return {
			state = active.state,
			xfer_id = active.xfer_id,
			direction = active.direction,
			size = active.size,
			offset = active.offset,
			checksum = active.checksum,
		}
	end

	local function publish_current()
		conn:retain(transfer_topic, statefmt.link_component('transfer', link_id, current_transfer_status()))
	end

	publish_current()

	local function clear_active(reason)
		if not active then
			publish_current()
			return
		end

		if active.direction == 'out' then
			fail_req(active.req, reason or 'aborted')
		elseif active.direction == 'in' then
			if active.sink and active.sink.abort then
				active.sink:abort()
			end
		end

		active = nil
		state.active = nil
		publish_current()
	end

	local function abort_active(reason)
		if not active then
			return
		end

		send_abort(tx_control, active.xfer_id, reason)
		clear_active(reason)
	end

	------------------------------------------------------------------
	-- Outgoing
	------------------------------------------------------------------

	-- active (outgoing) = {
	--   direction = 'out',
	--   xfer_id = <wire transfer id>,
	--   req = <local request awaiting completion>,
	--   source = <blob source>,
	--   size = <bytes>,
	--   checksum = <hex digest>,
	--   offset = <next offset to read/send>,
	--   state = 'waiting_ready' | 'sending' | 'committing',
	--   deadline = <phase timeout>,
	-- }
	local function begin_outgoing(req)
		if req:done() then return end
		if active then
			fail_req(req, 'busy')
			return
		end

		local payload = req.payload or {}
		local source, err = blob_source.normalise_source(payload.source)
		if not source then
			fail_req(req, err)
			return
		end

		local xfer_id = payload.xfer_id or tostring(uuid.new())
		local meta = payload.meta or {}
		if type(payload.receiver) == 'table' and meta.receiver == nil then
			meta.receiver = payload.receiver
		end

		active = {
			direction = 'out',
			xfer_id = xfer_id,
			req = req,
			source = source,
			size = source:size(),
			checksum = source:checksum(),
			offset = 0,
			state = 'waiting_ready',
			deadline = runtime.now() + phase_timeout,
		}
		state.active = active

		send_frame(tx_control, 'control', {
			type = 'xfer_begin',
			xfer_id = xfer_id,
			size = active.size,
			checksum = active.checksum,
			meta = meta,
		})

		publish_current()
	end

	local function maybe_send_outgoing_chunk(trigger_offset)
		if not active or active.direction ~= 'out' then return end
		if active.state ~= 'waiting_ready' and active.state ~= 'sending' then return end
		if trigger_offset ~= nil and trigger_offset ~= active.offset then return end

		if active.offset >= active.size then
			active.state = 'committing'
			active.deadline = runtime.now() + phase_timeout

			send_frame(tx_control, 'control', {
				type = 'xfer_commit',
				xfer_id = active.xfer_id,
				size = active.size,
				checksum = active.checksum,
			})

			publish_current()
			return
		end

		local raw, err = active.source:read_chunk(active.offset, chunk_size)
		if raw == nil then
			clear_active(err or 'source_error')
			return
		end

		local frame, ferr = protocol.make_xfer_chunk(active.xfer_id, active.offset, raw)
		if not frame then
			clear_active(ferr or 'chunk_encode_failed')
			return
		end

		active.state = 'sending'
		send_frame(tx_bulk, 'bulk', frame)

		active.offset = active.offset + #raw
		active.deadline = runtime.now() + phase_timeout

		publish_current()
	end

	------------------------------------------------------------------
	-- Incoming
	------------------------------------------------------------------

	-- active (incoming) = {
	--   direction = 'in',
	--   xfer_id = <wire transfer id>,
	--   size = <expected bytes>,
	--   checksum = <expected hex digest>,
	--   meta = <wire metadata>,
	--   sink = <sink receiving bytes>,
	--   offset = <next expected offset>,
	--   state = 'receiving' | 'delivering',
	--   deadline = <phase timeout>,
	-- }
	local function handle_incoming_begin(frame)
		if active then
			send_abort(tx_control, frame.xfer_id, 'busy')
			return
		end

		local sink_factory = ctx.open_incoming_sink or function(meta)
			return blob_source.memory_sink(meta), nil
		end

		local sink, serr = sink_factory(frame.meta, frame)
		if not sink then
			send_abort(tx_control, frame.xfer_id, tostring(serr or 'sink_open_failed'))
			return
		end

		active = {
			direction = 'in',
			xfer_id = frame.xfer_id,
			size = frame.size,
			checksum = frame.checksum,
			meta = frame.meta,
			sink = sink,
			offset = 0,
			state = 'receiving',
			deadline = runtime.now() + phase_timeout,
		}
		state.active = active

		send_frame(tx_control, 'control', {
			type = 'xfer_ready',
			xfer_id = frame.xfer_id,
		})

		publish_current()
	end

	local function handle_incoming_chunk(frame)
		if not active or active.direction ~= 'in' or frame.xfer_id ~= active.xfer_id then return end

		if frame.offset ~= active.offset then
			send_abort(tx_control, frame.xfer_id, 'unexpected_offset')
			clear_active('unexpected_offset')
			return
		end

		local raw, derr = protocol.read_xfer_chunk(frame)
		if raw == nil then
			send_abort(tx_control, frame.xfer_id, derr or 'invalid_chunk_encoding')
			clear_active(derr or 'invalid_chunk_encoding')
			return
		end

		local ok, err = active.sink:write_chunk(frame.offset, raw)
		if not ok then
			send_abort(tx_control, frame.xfer_id, err)
			clear_active(err)
			return
		end

		active.offset = active.offset + #raw
		active.deadline = runtime.now() + phase_timeout

		send_frame(tx_control, 'control', {
			type = 'xfer_need',
			xfer_id = frame.xfer_id,
			next = active.offset,
		})

		publish_current()
	end

	local function handle_incoming_commit(frame)
		if not active or active.direction ~= 'in' or frame.xfer_id ~= active.xfer_id then return end

		if frame.size ~= active.size or frame.checksum ~= active.checksum then
			send_abort(tx_control, frame.xfer_id, 'commit_mismatch')
			clear_active('commit_mismatch')
			return
		end

		if active.offset ~= active.size then
			send_abort(tx_control, frame.xfer_id, 'short_transfer')
			clear_active('short_transfer')
			return
		end

		if active.sink:checksum() ~= active.checksum then
			send_abort(tx_control, frame.xfer_id, 'checksum_mismatch')
			clear_active('checksum_mismatch')
			return
		end

		local artefact, cerr = active.sink:commit()
		if not artefact then
			send_abort(tx_control, frame.xfer_id, tostring(cerr or 'commit_failed'))
			clear_active(tostring(cerr or 'commit_failed'))
			return
		end

		local receiver_topic = active.meta and active.meta.receiver or nil
		if type(receiver_topic) == 'table' then
			active.state = 'delivering'
			publish_current()

			local reply, err = conn:call(receiver_topic, {
				link_id = link_id,
				xfer_id = active.xfer_id,
				size = active.size,
				checksum = active.checksum,
				meta = active.meta,
				artefact = artefact,
			}, { timeout = phase_timeout })

			if reply == nil then
				artefact:delete()
				send_abort(tx_control, frame.xfer_id, tostring(err or 'receiver_failed'))
				clear_active(tostring(err or 'receiver_failed'))
				return
			end
		end

		send_frame(tx_control, 'control', {
			type = 'xfer_done',
			xfer_id = frame.xfer_id,
		})

		active.state = 'done'
		publish_current()
		active = nil
		state.active = nil
	end

	------------------------------------------------------------------
	-- Requests and frames
	------------------------------------------------------------------

	local function current_status_snapshot()
		local status = {
			ok = true,
			active = active and {
				xfer_id = active.xfer_id,
				state = active.state,
				size = active.size,
				offset = active.offset,
				direction = active.direction,
			} or nil,
			outgoing = nil,
			incoming = nil,
		}

		if active and active.direction == 'out' then
			status.outgoing = status.active
		elseif active and active.direction == 'in' then
			status.incoming = status.active
		end

		return status
	end

	local function handle_control_request(req)
		if req:done() then return end

		local payload = req.payload or {}
		local op_name = payload.op

		if op_name == 'send_blob' then
			begin_outgoing(req)
		elseif op_name == 'status' then
			reply_req(req, current_status_snapshot())
		elseif op_name == 'abort' then
			abort_active(payload.reason or 'aborted')
			reply_req(req, { ok = true })
		else
			fail_req(req, 'unsupported_op')
		end
	end

	local function handle_transfer_frame(frame)
		if frame.type == 'xfer_begin' then
			handle_incoming_begin(frame)

		elseif frame.type == 'xfer_ready' then
			if active and active.direction == 'out' and frame.xfer_id == active.xfer_id then
				active.state = 'sending'
				active.deadline = runtime.now() + phase_timeout
				maybe_send_outgoing_chunk(0)
			end

		elseif frame.type == 'xfer_need' then
			if active and active.direction == 'out' and frame.xfer_id == active.xfer_id then
				maybe_send_outgoing_chunk(frame.next)
			end

		elseif frame.type == 'xfer_commit' then
			handle_incoming_commit(frame)

		elseif frame.type == 'xfer_done' then
			if active and active.direction == 'out' and frame.xfer_id == active.xfer_id then
				reply_req(active.req, {
					ok = true,
					xfer_id = active.xfer_id,
					size = active.size,
					checksum = active.checksum,
				})
				active.state = 'done'
				publish_current()
				active = nil
				state.active = nil
			end

		elseif frame.type == 'xfer_abort' then
			if active and frame.xfer_id == active.xfer_id then
				clear_active(frame.err or 'remote_abort')
			end

		elseif frame.type == 'xfer_chunk' then
			handle_incoming_chunk(frame)
		end
	end

	while true do
		state.session_seen = session_seen
		local which, a, b = perform(next_transfer_event_op(state))

		if which == 'ctl' and a then
			handle_control_request(a)

		elseif which == 'xfer' and a then
			handle_transfer_frame(a.msg or a)

		elseif which == 'session' then
			session_seen = a or session_seen
			local snap = b or session:get()
			if snap.generation ~= last_generation then
				last_generation = snap.generation
				abort_active('session_reset')
			end

		elseif which == 'timeout' then
			local now = runtime.now()
			if active and active.deadline <= now then
				if active.direction == 'out' then
					clear_active('timeout')
				else
					clear_active('timeout')
				end
			end
		end
	end
end

return M
