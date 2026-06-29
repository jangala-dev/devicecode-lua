-- services/fabric/state.lua
--
-- Fabric retained-state projector.
--
-- Components do not publish retained bus state through callbacks.  They emit
-- snapshot events to this owner; this owner is the only Fabric module that maps
-- Fabric runtime snapshots onto the local retained state plane.

local fibers      = require 'fibers'
local mailbox     = require 'fibers.mailbox'
local queue       = require 'devicecode.support.queue'
local bus_cleanup = require 'devicecode.support.bus_cleanup'
local topics      = require 'services.fabric.topics'
local contracts   = require 'devicecode.support.contracts'
local tablex      = require 'shared.table'

local M = {}

local DEFAULT_QUEUE_LEN = 64

local shallow_copy = tablex.shallow_copy

local function require_rx(v, name, level)
	return contracts.require_rx(v, name, (level or 1) + 1)
end

local function make_payload(kind, snapshot, opts)
	opts = opts or {}
	return {
		kind            = kind,
		link_id         = opts.link_id,
		link_generation = opts.link_generation,
		component       = opts.component,
		state           = type(snapshot) == 'table' and snapshot.state or nil,
		snapshot        = type(snapshot) == 'table' and shallow_copy(snapshot) or snapshot,
		ts              = fibers.now(),
	}
end

function M.link_topic(link_id)
	return topics.state_link(link_id)
end

function M.component_topic(link_id, component)
	return topics.state_link_component(link_id, component)
end

function M.transfer_topic(xfer_id)
	return topics.state_transfer(xfer_id)
end

function M.link_snapshot_event(link_id, link_generation, snapshot)
	return {
		kind = 'link_snapshot',
		link_id = link_id,
		link_generation = link_generation,
		snapshot = snapshot,
	}
end

function M.component_snapshot_event(link_id, link_generation, component, snapshot)
	return {
		kind = 'component_snapshot',
		link_id = link_id,
		link_generation = link_generation,
		component = component,
		snapshot = snapshot,
	}
end

function M.wire_trace_event(payload)
	return {
		kind = 'wire_trace',
		payload = type(payload) == 'table' and shallow_copy(payload) or { value = payload },
	}
end

function M.admit_wire_trace_now(tx, payload, label)
	if tx == nil then return true, nil end
	return queue.try_admit_required(
		tx,
		M.wire_trace_event(payload),
		label or 'fabric_wire_trace_admit_failed'
	)
end

function M.clear_link_event(link_id)
	return { kind = 'clear_link', link_id = link_id }
end

function M.clear_component_event(link_id, component)
	return { kind = 'clear_component', link_id = link_id, component = component }
end

function M.admit_link_snapshot_now(tx, link_id, link_generation, snapshot, label)
	if tx == nil then return true, nil end
	return queue.try_admit_required(
		tx,
		M.link_snapshot_event(link_id, link_generation, snapshot),
		label or 'fabric_state_link_snapshot_admit_failed'
	)
end

function M.admit_component_snapshot_now(tx, link_id, link_generation, component, snapshot, label)
	if tx == nil then return true, nil end
	return queue.try_admit_required(
		tx,
		M.component_snapshot_event(link_id, link_generation, component, snapshot),
		label or 'fabric_state_component_snapshot_admit_failed'
	)
end

function M.new_queue(len)
	return mailbox.new(len or DEFAULT_QUEUE_LEN, { full = 'reject_newest' })
end

local function retain(conn, topic, payload, opts)
	if conn == nil then return true, nil end
	return bus_cleanup.retain(conn, topic, payload, opts)
end

local function unretain(conn, topic, opts)
	if conn == nil then return true, nil end
	return bus_cleanup.unretain(conn, topic, opts)
end


local function transfer_corr_from_result(result)
	result = type(result) == 'table' and result or {}
	return {
		job_id = result.job_id,
		component = result.component,
		image_id = result.image_id,
		xfer_id = result.xfer_id,
		request_id = result.request_id,
	}
end

local function is_transfer_component(name)
	-- Historical code used component name "transfer"; current links publish the
	-- manager snapshot under the component name "transfer_manager".  Treat both
	-- as the transfer manager for retained transfer topics and monitor events.
	return name == 'transfer' or name == 'transfer_manager'
end

local function transfer_payload_from_snapshot(link_id, link_generation, snapshot)
	if type(snapshot) ~= 'table' then return nil end
	local rec = type(snapshot.active) == 'table' and snapshot.active or type(snapshot.last) == 'table' and snapshot.last or nil
	if type(rec) ~= 'table' then return nil end
	local result = type(rec.result) == 'table' and rec.result or {}
	local xfer_id = rec.xfer_id or result.xfer_id
	if type(xfer_id) ~= 'string' or xfer_id == '' then return nil end
	local meta = type(rec.meta) == 'table' and rec.meta or {}
	local corr = transfer_corr_from_result(result)
	corr.job_id = corr.job_id or meta.job_id
	corr.component = corr.component or meta.component
	corr.image_id = corr.image_id or meta.image_id
	corr.xfer_id = xfer_id
	corr.request_id = corr.request_id or rec.request_id or result.request_id
	return {
		kind = 'fabric.transfer',
		link_id = link_id,
		link_generation = link_generation,
		xfer_id = xfer_id,
		request_id = rec.request_id or result.request_id,
		direction = rec.direction,
		state = rec.status,
		status = rec.status,
		target = rec.target or result.target,
		size = result.size or rec.size,
		sent_bytes = result.sent_bytes,
		received_bytes = result.received_bytes,
		digest_alg = result.digest_alg or rec.digest_alg,
		digest = result.digest or rec.digest,
		retransmits = result.retransmits,
		chunk_retries = result.chunk_retries,
		chunks_sent = result.chunks_sent,
		max_frame_queue_ms = result.max_frame_queue_ms,
		max_need_to_chunk_ms = result.max_need_to_chunk_ms,
		max_source_read_ms = result.max_source_read_ms,
		max_send_ms = result.max_send_ms,
		progress = type(rec.progress) == 'table' and shallow_copy(rec.progress) or nil,
		error = rec.primary,
		correlation = corr,
		ts = fibers.now(),
	}
end

local function transfer_bytes(progress, payload)
	progress = type(progress) == 'table' and progress or {}
	payload = type(payload) == 'table' and payload or {}
	return payload.sent_bytes
		or payload.received_bytes
		or progress.sent_bytes
		or progress.received_bytes
		or progress.last_tx_next
		or progress.requested_next
		or progress.pending_next
		or progress.last_rx_next
end

local function field(v)
	if v == nil then return '-' end
	return tostring(v)
end

local function pct(bytes, total)
	if type(bytes) ~= 'number' or type(total) ~= 'number' or total <= 0 then return nil end
	return math.floor((bytes * 10000 / total) + 0.5) / 100
end

local function compact_transfer_obs_payload(payload)
	if type(payload) ~= 'table' then return nil end
	local progress = type(payload.progress) == 'table' and payload.progress or {}
	local bytes = transfer_bytes(progress, payload)
	local total = payload.size or progress.size or progress.total_bytes
	local rx = field(progress.last_rx_type) .. ':' .. field(progress.last_rx_next)
	local tx = field(progress.last_tx_type) .. ':' .. field(progress.last_tx_offset) .. '->' .. field(progress.last_tx_next)
	local out = {
		kind = 'fabric.transfer_progress',
		xfer_id = payload.xfer_id,
		request_id = payload.request_id,
		link_id = payload.link_id,
		link_generation = payload.link_generation,
		target = payload.target,
		phase = progress.phase or payload.status or payload.state,
		state = payload.state,
		status = payload.status,
		event = progress.event,
		bytes_transferred = bytes,
		total_bytes = total,
		percent = pct(bytes, total),
		last_rx_type = progress.last_rx_type,
		last_rx_next = progress.last_rx_next,
		last_tx_type = progress.last_tx_type,
		last_tx_offset = progress.last_tx_offset,
		last_tx_next = progress.last_tx_next,
		chunk_len = progress.chunk_len,
		chunk_digest = progress.chunk_digest,
		chunk_frame_len = progress.chunk_frame_len,
		chunks_sent = progress.chunks_sent or payload.chunks_sent,
		retransmits = progress.retransmits or payload.retransmits,
		retransmit = progress.retransmit,
		retry = progress.retry,
		retry_reason = progress.reason,
		frame_queue_ms = progress.frame_queue_ms,
		need_to_chunk_ms = progress.need_to_chunk_ms,
		source_read_ms = progress.source_read_ms,
		send_ms = progress.send_ms,
		max_frame_queue_ms = payload.max_frame_queue_ms or progress.max_frame_queue_ms,
		max_need_to_chunk_ms = payload.max_need_to_chunk_ms or progress.max_need_to_chunk_ms,
		max_source_read_ms = payload.max_source_read_ms or progress.max_source_read_ms,
		max_send_ms = payload.max_send_ms or progress.max_send_ms,
		error = payload.error or progress.err,
		job_id = type(payload.correlation) == 'table' and payload.correlation.job_id or nil,
		component = type(payload.correlation) == 'table' and payload.correlation.component or nil,
		image_id = type(payload.correlation) == 'table' and payload.correlation.image_id or nil,
		ts = fibers.now(),
	}
	out.summary = string.format(
		'xfer=%s phase=%s bytes=%s/%s rx=%s tx=%s len=%s digest=%s frame_len=%s retransmit=%s retry=%s reason=%s need_to_chunk_ms=%s frame_queue_ms=%s source_read_ms=%s send_ms=%s',
		field(out.xfer_id), field(out.phase), field(bytes), field(total), rx, tx,
		field(out.chunk_len), field(out.chunk_digest), field(out.chunk_frame_len), field(out.retransmit),
		field(out.retry), field(out.retry_reason),
		field(out.need_to_chunk_ms), field(out.frame_queue_ms), field(out.source_read_ms), field(out.send_ms)
	)
	return out
end

local function transfer_obs_key(payload)
	if type(payload) ~= 'table' then return nil end
	local progress = type(payload.progress) == 'table' and payload.progress or {}
	return table.concat({
		field(payload.xfer_id),
		field(payload.state or payload.status),
		field(progress.event),
		field(transfer_bytes(progress, payload)),
		field(progress.last_rx_type),
		field(progress.last_rx_next),
		field(progress.last_tx_type),
		field(progress.last_tx_offset),
		field(progress.last_tx_next),
		field(progress.chunk_len),
		field(progress.chunk_digest),
		field(progress.chunk_frame_len),
		field(progress.chunks_sent or payload.chunks_sent),
		field(progress.retransmits or payload.retransmits),
		field(progress.retransmit),
		field(progress.retry),
		field(progress.reason),
		field(payload.error or progress.err),
	}, '|')
end

local function publish_transfer_obs(conn, obs_state, payload)
	if conn == nil then return true, nil end
	local compact = compact_transfer_obs_payload(payload)
	if compact == nil or type(compact.xfer_id) ~= 'string' or compact.xfer_id == '' then return true, nil end
	local key = transfer_obs_key(payload)
	obs_state.transfer_keys = obs_state.transfer_keys or {}
	if obs_state.transfer_keys[compact.xfer_id] == key then return true, nil end
	obs_state.transfer_keys[compact.xfer_id] = key
	conn:publish({ 'obs', 'event', 'fabric', 'transfer_progress' }, compact)
	conn:publish({ 'obs', 'v1', 'fabric', 'event', 'transfer_progress' }, compact)
	return true, nil
end

local function handle_event(conn, ev, obs_state)
	obs_state = obs_state or {}
	if ev.kind == 'link_snapshot' then
		return retain(
			conn,
			M.link_topic(ev.link_id),
			make_payload('fabric.link', ev.snapshot, {
				link_id = ev.link_id,
				link_generation = ev.link_generation,
			})
		)

	elseif ev.kind == 'component_snapshot' then
		local ok, err = retain(
			conn,
			M.component_topic(ev.link_id, ev.component),
			make_payload('fabric.component', ev.snapshot, {
				link_id = ev.link_id,
				link_generation = ev.link_generation,
				component = ev.component,
			})
		)
		if ok ~= true then return ok, err end
		if is_transfer_component(ev.component) then
			local payload = transfer_payload_from_snapshot(ev.link_id, ev.link_generation, ev.snapshot)
			if payload ~= nil then
				local rok, rerr = retain(conn, M.transfer_topic(payload.xfer_id), payload)
				if rok ~= true then return rok, rerr end
				return publish_transfer_obs(conn, obs_state, payload)
			end
		end
		return true, nil

	elseif ev.kind == 'wire_trace' then
		local payload = type(ev.payload) == 'table' and shallow_copy(ev.payload) or { value = ev.payload }
		payload.kind = payload.kind or 'fabric.wire'
		payload.ts = payload.ts or fibers.now()
		if conn ~= nil then
			conn:publish({ 'obs', 'event', 'fabric', 'wire' }, payload)
			conn:publish({ 'obs', 'v1', 'fabric', 'event', 'wire' }, payload)
		end
		return true, nil

	elseif ev.kind == 'clear_link' then
		return unretain(conn, M.link_topic(ev.link_id))

	elseif ev.kind == 'clear_component' then
		return unretain(conn, M.component_topic(ev.link_id, ev.component))
	end

	return nil, 'fabric state projector unknown event: ' .. tostring(ev.kind)
end

function M.run_projector(scope, params)
	if type(scope) ~= 'table' then
		error('fabric.state.run_projector: scope required', 2)
	end
	if type(params) ~= 'table' then
		error('fabric.state.run_projector: params table required', 2)
	end

	local rx = require_rx(params.state_rx, 'fabric.state: state_rx', 2)
	local conn = params.conn
	local count = 0
	local obs_state = { transfer_keys = {} }

	while true do
		local ev = fibers.perform(rx:recv_op())
		if ev == nil then
			return { role = 'state_projector', published = count, reason = rx.why and rx:why() or 'closed' }
		end

		local ok, err = handle_event(conn, ev, obs_state)
		if ok ~= true then
			error(err or 'fabric state projection failed', 0)
		end
		count = count + 1
	end
end

-- Immediate helpers retained for tests and administrative cleanup.  Core Fabric
-- components should use the projector event surface above.
function M.publish_link(conn, link_id, link_generation, snapshot, opts)
	opts = shallow_copy(opts or {})
	opts.link_id = link_id
	opts.link_generation = link_generation
	return retain(conn, M.link_topic(link_id), make_payload('fabric.link', snapshot, opts))
end

function M.publish_component(conn, link_id, link_generation, component, snapshot, opts)
	opts = shallow_copy(opts or {})
	opts.link_id = link_id
	opts.link_generation = link_generation
	opts.component = component
	return retain(conn, M.component_topic(link_id, component), make_payload('fabric.component', snapshot, opts))
end

function M.clear_link(conn, link_id)
	return unretain(conn, M.link_topic(link_id))
end

function M.clear_component(conn, link_id, component)
	return unretain(conn, M.component_topic(link_id, component))
end

return M
