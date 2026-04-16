-- services/fabric/transfer_mgr.lua

local fibers      = require 'fibers'
local runtime     = require 'fibers.runtime'
local sleep       = require 'fibers.sleep'
local uuid        = require 'uuid'

local blob_source = require 'services.fabric.blob_source'
local protocol    = require 'services.fabric.protocol'

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

local function reply_job(job, payload)
	if not job or not job.reply_tx then return end
	job.reply_tx:send(payload)
end

local function publish_state(conn, link_id, payload)
	pcall(function() conn:retain({ 'state', 'fabric', 'link', link_id, 'transfer' }, payload) end)
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

	local outgoing = nil
	local incoming = nil
	local session_seen = session:pulse():version()
	local last_generation = session:get().generation

	publish_state(conn, link_id, { state = 'idle', ts = runtime.now() })

	local function clear_outgoing(reason)
		if outgoing and outgoing.job then
			reply_job(outgoing.job, { ok = false, err = reason or 'aborted', xfer_id = outgoing.xfer_id })
		end
		outgoing = nil
		publish_state(conn, link_id, { state = 'idle', ts = runtime.now() })
	end

	local function clear_incoming(reason)
		if incoming and incoming.sink and incoming.sink.abort then
			pcall(function() incoming.sink:abort() end)
		end
		incoming = nil
		publish_state(conn, link_id, { state = 'idle', ts = runtime.now(), err = reason })
	end

	local function abort_all(reason)
		if outgoing then
			send_frame(tx_control, 'control', { type = 'xfer_abort', xfer_id = outgoing.xfer_id, err = reason })
			clear_outgoing(reason)
		end
		if incoming then
			send_frame(tx_control, 'control', { type = 'xfer_abort', xfer_id = incoming.xfer_id, err = reason })
			clear_incoming(reason)
		end
	end

	local function publish_transfer(payload)
		payload.link_id = link_id
		payload.ts = runtime.now()
		publish_state(conn, link_id, payload)
	end

	local function begin_outgoing(job)
		if outgoing then
			reply_job(job, { ok = false, err = 'busy' })
			return
		end
		local source, err = blob_source.normalise_source(job.source)
		if not source then
			reply_job(job, { ok = false, err = err })
			return
		end
		local xfer_id = job.xfer_id or tostring(uuid.new())
		outgoing = {
			xfer_id = xfer_id,
			job = job,
			source = source,
			size = source:size(),
			checksum = source:checksum(),
			offset = 0,
			state = 'waiting_ready',
			deadline = runtime.now() + phase_timeout,
		}
		send_frame(tx_control, 'control', {
			type = 'xfer_begin',
			xfer_id = xfer_id,
			size = outgoing.size,
			checksum = outgoing.checksum,
			meta = job.meta,
		})
		publish_transfer({ state = outgoing.state, xfer_id = xfer_id, direction = 'out', size = outgoing.size, offset = 0 })
	end

	local function maybe_send_outgoing_chunk(trigger_offset)
		if not outgoing then return end
		if outgoing.state ~= 'waiting_ready' and outgoing.state ~= 'sending' then return end
		if trigger_offset ~= nil and trigger_offset ~= outgoing.offset then return end
		if outgoing.offset >= outgoing.size then
			outgoing.state = 'committing'
			outgoing.deadline = runtime.now() + phase_timeout
			send_frame(tx_control, 'control', { type = 'xfer_commit', xfer_id = outgoing.xfer_id, size = outgoing.size, checksum = outgoing.checksum })
			publish_transfer({ state = outgoing.state, xfer_id = outgoing.xfer_id, direction = 'out', size = outgoing.size, offset = outgoing.offset })
			return
		end
		local data, err = outgoing.source:read_chunk(outgoing.offset, chunk_size)
		if data == nil then
			clear_outgoing(err or 'source_error')
			return
		end
		outgoing.state = 'sending'
		send_frame(tx_bulk, 'bulk', { type = 'xfer_chunk', xfer_id = outgoing.xfer_id, offset = outgoing.offset, data = data })
		outgoing.offset = outgoing.offset + #data
		outgoing.deadline = runtime.now() + phase_timeout
		publish_transfer({ state = outgoing.state, xfer_id = outgoing.xfer_id, direction = 'out', size = outgoing.size, offset = outgoing.offset })
	end

	local function handle_incoming_begin(frame)
		if incoming then
			send_frame(tx_control, 'control', { type = 'xfer_abort', xfer_id = frame.xfer_id, err = 'busy' })
			return
		end
		incoming = {
			xfer_id = frame.xfer_id,
			size = frame.size,
			checksum = frame.checksum,
			sink = blob_source.memory_sink(),
			offset = 0,
			state = 'receiving',
			deadline = runtime.now() + phase_timeout,
		}
		send_frame(tx_control, 'control', { type = 'xfer_ready', xfer_id = frame.xfer_id })
		publish_transfer({ state = incoming.state, xfer_id = frame.xfer_id, direction = 'in', size = frame.size, offset = 0 })
	end

	local function handle_incoming_chunk(frame)
		if not incoming or frame.xfer_id ~= incoming.xfer_id then return end
		if frame.offset ~= incoming.offset then
			send_frame(tx_control, 'control', { type = 'xfer_abort', xfer_id = frame.xfer_id, err = 'unexpected_offset' })
			clear_incoming('unexpected_offset')
			return
		end
		local ok, err = incoming.sink:write_chunk(frame.offset, frame.data)
		if not ok then
			send_frame(tx_control, 'control', { type = 'xfer_abort', xfer_id = frame.xfer_id, err = err })
			clear_incoming(err)
			return
		end
		incoming.offset = incoming.offset + #frame.data
		incoming.deadline = runtime.now() + phase_timeout
		send_frame(tx_control, 'control', { type = 'xfer_need', xfer_id = frame.xfer_id, next = incoming.offset })
		publish_transfer({ state = incoming.state, xfer_id = frame.xfer_id, direction = 'in', size = incoming.size, offset = incoming.offset })
	end

	local function handle_incoming_commit(frame)
		if not incoming or frame.xfer_id ~= incoming.xfer_id then return end
		if incoming.offset ~= incoming.size then
			send_frame(tx_control, 'control', { type = 'xfer_abort', xfer_id = frame.xfer_id, err = 'short_transfer' })
			clear_incoming('short_transfer')
			return
		end
		if incoming.sink:checksum() ~= incoming.checksum then
			send_frame(tx_control, 'control', { type = 'xfer_abort', xfer_id = frame.xfer_id, err = 'checksum_mismatch' })
			clear_incoming('checksum_mismatch')
			return
		end
		incoming.sink:commit()
		send_frame(tx_control, 'control', { type = 'xfer_done', xfer_id = frame.xfer_id })
		publish_transfer({ state = 'done', xfer_id = frame.xfer_id, direction = 'in', size = incoming.size, offset = incoming.offset, checksum = incoming.checksum })
		incoming = nil
	end

	local function handle_job(job)
		if job.op == 'send_blob' then
			begin_outgoing(job)
		elseif job.op == 'status' then
			reply_job(job, {
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
			})
		elseif job.op == 'abort' then
			abort_all(job.reason or 'aborted')
			reply_job(job, { ok = true })
		else
			reply_job(job, { ok = false, err = 'unsupported_op' })
		end
	end

	local function handle_xfer_msg(frame)
		if frame.type == 'xfer_begin' then handle_incoming_begin(frame)
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
		elseif frame.type == 'xfer_commit' then handle_incoming_commit(frame)
		elseif frame.type == 'xfer_done' then
			if outgoing and frame.xfer_id == outgoing.xfer_id then
				reply_job(outgoing.job, { ok = true, xfer_id = outgoing.xfer_id, size = outgoing.size, checksum = outgoing.checksum })
				publish_transfer({ state = 'done', xfer_id = outgoing.xfer_id, direction = 'out', size = outgoing.size, offset = outgoing.offset, checksum = outgoing.checksum })
				outgoing = nil
			end
		elseif frame.type == 'xfer_abort' then
			if outgoing and frame.xfer_id == outgoing.xfer_id then clear_outgoing(frame.err or 'remote_abort') end
			if incoming and frame.xfer_id == incoming.xfer_id then clear_incoming(frame.err or 'remote_abort') end
		elseif frame.type == 'xfer_chunk' then handle_incoming_chunk(frame)
		end
	end

	while true do
		local snap = session:get()
		if snap.generation ~= last_generation then
			last_generation = snap.generation
			abort_all('session_reset')
		end

		local nearest = math.huge
		if outgoing and outgoing.deadline < nearest then nearest = outgoing.deadline end
		if incoming and incoming.deadline < nearest then nearest = incoming.deadline end

		local ops = {
			ctl = transfer_ctl_rx:recv_op(),
			xfer = xfer_rx:recv_op(),
			session = session:pulse():changed_op(session_seen),
		}
		if nearest < math.huge then
			local dt = nearest - runtime.now()
			if dt < 0 then dt = 0 end
			ops.timeout = sleep.sleep_op(dt):wrap(function() return true end)
		end

		local which, item = fibers.perform(fibers.named_choice(ops))
		if which == 'ctl' and item then
			handle_job(item)
		elseif which == 'xfer' and item then
			handle_xfer_msg(item.msg or item)
		elseif which == 'session' then
			session_seen = item or session_seen
		elseif which == 'timeout' then
			local now = runtime.now()
			if outgoing and outgoing.deadline <= now then clear_outgoing('timeout') end
			if incoming and incoming.deadline <= now then clear_incoming('timeout') end
		end
	end
end

return M
