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
		error = rec.primary,
		correlation = corr,
		ts = fibers.now(),
	}
end

local function handle_event(conn, ev)
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
		if ev.component == 'transfer' then
			local payload = transfer_payload_from_snapshot(ev.link_id, ev.link_generation, ev.snapshot)
			if payload ~= nil then
				return retain(conn, M.transfer_topic(payload.xfer_id), payload)
			end
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

	while true do
		local ev = fibers.perform(rx:recv_op())
		if ev == nil then
			return { role = 'state_projector', published = count, reason = rx.why and rx:why() or 'closed' }
		end

		local ok, err = handle_event(conn, ev)
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
