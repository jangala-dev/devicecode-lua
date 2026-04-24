-- services/fabric/transfer_mgr.lua
--
-- Per-link transfer manager.
--
-- Responsibilities:
--   * own one active outgoing transfer per link
--   * own one active incoming transfer per link
--   * reset both directions on session generation change
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

-- Transfer shell event selection.
--
-- state contains:
--   * transfer_ctl_rx
--   * xfer_rx
--   * session / session_seen
--   * outgoing :: active outgoing record | nil
--   * incoming :: active incoming record | nil
local function next_transfer_event_op(state)
	local ops = {
		ctl = state.transfer_ctl_rx:recv_op(),
		xfer = state.xfer_rx:recv_op(),
		session = state.session:changed_op(state.session_seen),
	}

	local nearest = math.huge
	if state.outgoing and state.outgoing.deadline < nearest then
		nearest = state.outgoing.deadline
	end
	if state.incoming and state.incoming.deadline < nearest then
		nearest = state.incoming.deadline
	end

	if nearest < math.huge then
		local dt = nearest - runtime.now()
		if dt < 0 then dt = 0 end
		ops.timeout = sleep.sleep_op(dt):wrap(function()
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

	local outgoing = nil
	local incoming = nil
	local session_seen = session:pulse():version()
	local last_generation = session:get().generation

	local state = {
		session = session,
		xfer_rx = xfer_rx,
		transfer_ctl_rx = transfer_ctl_rx,
		session_seen = session_seen,
		outgoing = outgoing,
		incoming = incoming,
	}

	local function publish_state(status)
		conn:retain(transfer_topic, statefmt.link_component('transfer', link_id, status))
	end

	publish_state({ state = 'idle' })

	local function clear_outgoing(reason)
		if outgoing and outgoing.req then
			fail_req(outgoing.req, reason or 'aborted')
		end
		outgoing = nil
		state.outgoing = nil
		publish_state({ state = 'idle', err = reason })
	end

	local function clear_incoming(reason)
		if incoming and incoming.sink and incoming.sink.abort then
			incoming.sink:abort()
		end
		incoming = nil
		state.incoming = nil
		publish_state({ state = 'idle', err = reason })
	end

	local function abort_all(reason)
		-- Generation changes and fatal protocol errors reset both directions.
		if outgoing then
			send_frame(tx_control, 'control', {
				type = 'xfer_abort',
				xfer_id = outgoing.xfer_id,
				err = reason,
			})
			clear_outgoing(reason)
		end
		if incoming then
			send_frame(tx_control, 'control', {
				type = 'xfer_abort',
				xfer_id = incoming.xfer_id,
				err = reason,
			})
			clear_incoming(reason)
		end
	end

	local function publish_transfer_state(status)
		publish_state(status)
	end

	------------------------------------------------------------------
	-- Outgoing
	------------------------------------------------------------------

	-- outgoing = {
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
		if outgoing then
			fail_req(req, 'busy')
			return
		end

		local payload = req.payload or {}
		local source, err = blob_source.normalise_source(payload.source or payload.data)
		if not source then
			fail_req(req, err)
			return
		end

		local xfer_id = payload.xfer_id or tostring(uuid.new())
		local meta = payload.meta or {}
		if type(payload.receiver) == 'table' and meta.receiver == nil then
			meta.receiver = payload.receiver
		end

		outgoing = {
			xfer_id = xfer_id,
			req = req,
			source = source,
			size = source:size(),
			checksum = source:checksum(),
			offset = 0,
			state = 'waiting_ready',
			deadline = runtime.now() + phase_timeout,
		}
		state.outgoing = outgoing

		send_frame(tx_control, 'control', {
			type = 'xfer_begin',
			xfer_id = xfer_id,
			size = outgoing.size,
			checksum = outgoing.checksum,
			meta = meta,
		})

		publish_transfer_state({
			state = outgoing.state,
			xfer_id = xfer_id,
			direction = 'out',
			size = outgoing.size,
			offset = 0,
		})
	end

	local function maybe_send_outgoing_chunk(trigger_offset)
		if not outgoing then return end
		if outgoing.state ~= 'waiting_ready' and outgoing.state ~= 'sending' then return end
		if trigger_offset ~= nil and trigger_offset ~= outgoing.offset then return end

		if outgoing.offset >= outgoing.size then
			outgoing.state = 'committing'
			outgoing.deadline = runtime.now() + phase_timeout

			send_frame(tx_control, 'control', {
				type = 'xfer_commit',
				xfer_id = outgoing.xfer_id,
				size = outgoing.size,
				checksum = outgoing.checksum,
			})

			publish_transfer_state({
				state = outgoing.state,
				xfer_id = outgoing.xfer_id,
				direction = 'out',
				size = outgoing.size,
				offset = outgoing.offset,
			})
			return
		end

		local data, err = outgoing.source:read_chunk(outgoing.offset, chunk_size)
		if data == nil then
			clear_outgoing(err or 'source_error')
			return
		end

		outgoing.state = 'sending'
		send_frame(tx_bulk, 'bulk', {
			type = 'xfer_chunk',
			xfer_id = outgoing.xfer_id,
			offset = outgoing.offset,
			data = data,
		})

		outgoing.offset = outgoing.offset + #data
		outgoing.deadline = runtime.now() + phase_timeout

		publish_transfer_state({
			state = outgoing.state,
			xfer_id = outgoing.xfer_id,
			direction = 'out',
			size = outgoing.size,
			offset = outgoing.offset,
		})
	end

	------------------------------------------------------------------
	-- Incoming
	------------------------------------------------------------------

	-- incoming = {
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
		if incoming then
			send_frame(tx_control, 'control', {
				type = 'xfer_abort',
				xfer_id = frame.xfer_id,
				err = 'busy',
			})
			return
		end

		local sink_factory = ctx.open_incoming_sink or function(meta)
			return blob_source.memory_sink(meta), nil
		end

		local sink, serr = sink_factory(frame.meta, frame)
		if not sink then
			send_frame(tx_control, 'control', {
				type = 'xfer_abort',
				xfer_id = frame.xfer_id,
				err = tostring(serr or 'sink_open_failed'),
			})
			return
		end

		incoming = {
			xfer_id = frame.xfer_id,
			size = frame.size,
			checksum = frame.checksum,
			meta = frame.meta,
			sink = sink,
			offset = 0,
			state = 'receiving',
			deadline = runtime.now() + phase_timeout,
		}
		state.incoming = incoming

		send_frame(tx_control, 'control', {
			type = 'xfer_ready',
			xfer_id = frame.xfer_id,
		})

		publish_transfer_state({
			state = incoming.state,
			xfer_id = frame.xfer_id,
			direction = 'in',
			size = frame.size,
			offset = 0,
		})
	end

	local function handle_incoming_chunk(frame)
		if not incoming or frame.xfer_id ~= incoming.xfer_id then return end

		if frame.offset ~= incoming.offset then
			send_frame(tx_control, 'control', {
				type = 'xfer_abort',
				xfer_id = frame.xfer_id,
				err = 'unexpected_offset',
			})
			clear_incoming('unexpected_offset')
			return
		end

		local ok, err = incoming.sink:write_chunk(frame.offset, frame.data)
		if not ok then
			send_frame(tx_control, 'control', {
				type = 'xfer_abort',
				xfer_id = frame.xfer_id,
				err = err,
			})
			clear_incoming(err)
			return
		end

		incoming.offset = incoming.offset + #frame.data
		incoming.deadline = runtime.now() + phase_timeout

		send_frame(tx_control, 'control', {
			type = 'xfer_need',
			xfer_id = frame.xfer_id,
			next = incoming.offset,
		})

		publish_transfer_state({
			state = incoming.state,
			xfer_id = incoming.xfer_id,
			direction = 'in',
			size = incoming.size,
			offset = incoming.offset,
		})
	end

	local function handle_incoming_commit(frame)
		if not incoming or frame.xfer_id ~= incoming.xfer_id then return end

		if incoming.offset ~= incoming.size then
			send_frame(tx_control, 'control', {
				type = 'xfer_abort',
				xfer_id = frame.xfer_id,
				err = 'short_transfer',
			})
			clear_incoming('short_transfer')
			return
		end

		if incoming.sink:checksum() ~= incoming.checksum then
			send_frame(tx_control, 'control', {
				type = 'xfer_abort',
				xfer_id = frame.xfer_id,
				err = 'checksum_mismatch',
			})
			clear_incoming('checksum_mismatch')
			return
		end

		local artefact, cerr = incoming.sink:commit()
		if not artefact then
			send_frame(tx_control, 'control', {
				type = 'xfer_abort',
				xfer_id = frame.xfer_id,
				err = tostring(cerr or 'commit_failed'),
			})
			clear_incoming(tostring(cerr or 'commit_failed'))
			return
		end

		local receiver = incoming.meta and incoming.meta.receiver or nil
		if type(receiver) == 'table' then
			incoming.state = 'delivering'
			publish_transfer_state({
				state = incoming.state,
				xfer_id = incoming.xfer_id,
				direction = 'in',
				size = incoming.size,
				offset = incoming.offset,
			})

			local reply, err = conn:call(receiver, {
				link_id = link_id,
				xfer_id = incoming.xfer_id,
				size = incoming.size,
				checksum = incoming.checksum,
				meta = incoming.meta,
				artefact = artefact,
			}, { timeout = phase_timeout })

			if reply == nil then
				artefact:delete()
				send_frame(tx_control, 'control', {
					type = 'xfer_abort',
					xfer_id = frame.xfer_id,
					err = tostring(err or 'receiver_failed'),
				})
				clear_incoming(tostring(err or 'receiver_failed'))
				return
			end
		end

		send_frame(tx_control, 'control', {
			type = 'xfer_done',
			xfer_id = frame.xfer_id,
		})

		publish_transfer_state({
			state = 'done',
			xfer_id = frame.xfer_id,
			direction = 'in',
			size = incoming.size,
			offset = incoming.offset,
			checksum = incoming.checksum,
		})

		incoming = nil
		state.incoming = nil
	end

	------------------------------------------------------------------
	-- Requests and frames
	------------------------------------------------------------------

	local function current_status_snapshot()
		return {
			ok = true,
			outgoing = outgoing and {
				xfer_id = outgoing.xfer_id,
				state = outgoing.state,
				size = outgoing.size,
				offset = outgoing.offset,
			},
			incoming = incoming and {
				xfer_id = incoming.xfer_id,
				state = incoming.state,
				size = incoming.size,
				offset = incoming.offset,
			},
		}
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
			abort_all(payload.reason or 'aborted')
			reply_req(req, { ok = true })
		else
			fail_req(req, 'unsupported_op')
		end
	end

	local function handle_transfer_frame(frame)
		if frame.type == 'xfer_begin' then
			handle_incoming_begin(frame)

		elseif frame.type == 'xfer_ready' then
			if outgoing and frame.xfer_id == outgoing.xfer_id then
				outgoing.state = 'sending'
				outgoing.deadline = runtime.now() + phase_timeout
				maybe_send_outgoing_chunk(0)
			end

		elseif frame.type == 'xfer_need' then
			if outgoing and frame.xfer_id == outgoing.xfer_id then
				maybe_send_outgoing_chunk(frame.next)
			end

		elseif frame.type == 'xfer_commit' then
			handle_incoming_commit(frame)

		elseif frame.type == 'xfer_done' then
			if outgoing and frame.xfer_id == outgoing.xfer_id then
				reply_req(outgoing.req, {
					ok = true,
					xfer_id = outgoing.xfer_id,
					size = outgoing.size,
					checksum = outgoing.checksum,
				})
				publish_transfer_state({
					state = 'done',
					xfer_id = outgoing.xfer_id,
					direction = 'out',
					size = outgoing.size,
					offset = outgoing.offset,
					checksum = outgoing.checksum,
				})
				outgoing = nil
				state.outgoing = nil
			end

		elseif frame.type == 'xfer_abort' then
			if outgoing and frame.xfer_id == outgoing.xfer_id then
				clear_outgoing(frame.err or 'remote_abort')
			end
			if incoming and frame.xfer_id == incoming.xfer_id then
				clear_incoming(frame.err or 'remote_abort')
			end

		elseif frame.type == 'xfer_chunk' then
			handle_incoming_chunk(frame)
		end
	end

	while true do
		local snap = session:get()
		if snap.generation ~= last_generation then
			last_generation = snap.generation
			abort_all('session_reset')
		end

		state.session_seen = session_seen
		local which, a, b = perform(next_transfer_event_op(state))

		if which == 'ctl' and a then
			handle_control_request(a)

		elseif which == 'xfer' and a then
			handle_transfer_frame(a.msg or a)

		elseif which == 'session' then
			session_seen = a or session_seen
			local snap2 = b or session:get()
			if snap2.generation ~= last_generation then
				last_generation = snap2.generation
				abort_all('session_reset')
			end

		elseif which == 'timeout' then
			local now = runtime.now()
			if outgoing and outgoing.deadline <= now then clear_outgoing('timeout') end
			if incoming and incoming.deadline <= now then clear_incoming('timeout') end
		end
	end
end

return M
