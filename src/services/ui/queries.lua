-- services/ui/queries.lua
--
-- Pure read-only projections over read-model snapshots.

local topics = require 'services.ui.topics'
local tablex = require 'shared.table'
local topicx = require 'shared.topic'

local M = {}

local copy_value = tablex.deep_copy

local topic_has_prefix = topicx.starts_with

local function sorted_items(snapshot, pred)
	local out = {}
	for _, msg in pairs((snapshot and snapshot.items) or {}) do
		if not pred or pred(msg) then
			out[#out + 1] = copy_value(msg)
		end
	end
	table.sort(out, function(a, b)
		return topics.topic_key(a.topic) < topics.topic_key(b.topic)
	end)
	return out
end

function M.all(snapshot)
	return {
		version = snapshot and snapshot.version or 0,
		items = sorted_items(snapshot),
	}
end

function M.topic(snapshot, topic)
	local key = topics.topic_key(topic)
	local item = snapshot and snapshot.items and snapshot.items[key]
	return item and copy_value(item) or nil
end

function M.pattern(snapshot, pattern, matcher)
	if matcher then
		return sorted_items(snapshot, function(msg) return matcher(pattern, msg.topic) end)
	end
	return sorted_items(snapshot, function(msg)
		return topic_has_prefix(msg.topic, pattern)
	end)
end

function M.services_snapshot(snapshot)
	return {
		version = snapshot and snapshot.version or 0,
		services = sorted_items(snapshot, function(msg)
			return topic_has_prefix(msg.topic, { 'svc' })
		end),
	}
end

function M.fabric_status(snapshot)
	return {
		version = snapshot and snapshot.version or 0,
		status = sorted_items(snapshot, function(msg)
			return topic_has_prefix(msg.topic, { 'state', 'fabric' })
				or topic_has_prefix(msg.topic, { 'svc', 'fabric' })
		end),
	}
end

function M.update_jobs_snapshot(snapshot)
	return {
		version = snapshot and snapshot.version or 0,
		jobs = sorted_items(snapshot, function(msg)
			return topic_has_prefix(msg.topic, { 'state', 'workflow', 'update-job' })
				or topic_has_prefix(msg.topic, { 'state', 'update' })
		end),
	}
end


local function payload_of(msg)
	return type(msg) == 'table' and type(msg.payload) == 'table' and msg.payload or nil
end

local function topic_len(topic)
	return type(topic) == 'table' and #topic or 0
end

local function topic_at(topic, i)
	return type(topic) == 'table' and topic[i] or nil
end

local function is_update_job_topic(topic)
	return topic_len(topic) == 4
		and topic_at(topic, 1) == 'state'
		and topic_at(topic, 2) == 'workflow'
		and topic_at(topic, 3) == 'update-job'
end

local function is_update_timeline_topic(topic)
	return topic_len(topic) == 5
		and topic_at(topic, 1) == 'state'
		and topic_at(topic, 2) == 'workflow'
		and topic_at(topic, 3) == 'update-job'
		and topic_at(topic, 5) == 'timeline'
end

local function is_fabric_transfer_topic(topic)
	return topic_len(topic) == 4
		and topic_at(topic, 1) == 'state'
		and topic_at(topic, 2) == 'fabric'
		and topic_at(topic, 3) == 'transfer'
end

local function is_terminal_job_state(state)
	return state == 'succeeded'
		or state == 'failed'
		or state == 'cancelled'
		or state == 'timed_out'
		or state == 'discarded'
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

local function transfer_total(progress, payload)
	progress = type(progress) == 'table' and progress or {}
	payload = type(payload) == 'table' and payload or {}
	return payload.size or progress.size or progress.total_bytes
end

local function augment_transfer(payload)
	local out = copy_value(payload or {})
	local progress = type(out.progress) == 'table' and out.progress or {}
	local bytes = transfer_bytes(progress, out)
	local total = transfer_total(progress, out)
	out.bytes_transferred = bytes
	out.total_bytes = total
	if type(bytes) == 'number' and type(total) == 'number' and total > 0 then
		out.percent = math.floor((bytes * 10000 / total) + 0.5) / 100
	end
	out.last_rx = {
		type = progress.last_rx_type,
		next = progress.last_rx_next,
		at = progress.last_rx_at,
	}
	out.last_tx = {
		type = progress.last_tx_type,
		offset = progress.last_tx_offset,
		next = progress.last_tx_next,
		at = progress.last_tx_at,
	}
	out.timing = {
		frame_queue_ms = progress.frame_queue_ms,
		need_to_chunk_ms = progress.need_to_chunk_ms,
		source_read_ms = progress.source_read_ms,
		send_ms = progress.send_ms,
		max_frame_queue_ms = out.max_frame_queue_ms or progress.max_frame_queue_ms,
		max_need_to_chunk_ms = out.max_need_to_chunk_ms or progress.max_need_to_chunk_ms,
		max_source_read_ms = out.max_source_read_ms or progress.max_source_read_ms,
		max_send_ms = out.max_send_ms or progress.max_send_ms,
	}
	return out
end

local function transfer_job_id(transfer)
	local corr = type(transfer) == 'table' and type(transfer.correlation) == 'table' and transfer.correlation or nil
	return corr and corr.job_id or nil
end

local function transfer_is_active(transfer)
	local st = transfer and (transfer.state or transfer.status)
	return st == 'leased' or st == 'sending' or st == 'receiving' or st == 'staging'
end

local function newest_job_first(a, b)
	local av = type(a) == 'table' and (a.updated_seq or a.seq or 0) or 0
	local bv = type(b) == 'table' and (b.updated_seq or b.seq or 0) or 0
	if av == bv then return tostring(a and a.job_id or '') > tostring(b and b.job_id or '') end
	return av > bv
end

local function newest_transfer_first(a, b)
	local av = type(a) == 'table' and (a.ts or 0) or 0
	local bv = type(b) == 'table' and (b.ts or 0) or 0
	if av == bv then return tostring(a and a.xfer_id or '') > tostring(b and b.xfer_id or '') end
	return av > bv
end

--- HTTP-friendly update status, including live Fabric transfer progress.
---
--- This is deliberately a projection over retained state rather than another
--- update-service RPC.  It lets curl-based harnesses poll one endpoint while an
--- upload/start request is already in flight.
function M.update_status(snapshot)
	local items = snapshot and snapshot.items or {}
	local summary = nil
	local jobs = {}
	local timelines = {}
	local transfers = {}
	local active_job = nil
	local active_transfer = nil

	for _, msg in pairs(items) do
		local topic = msg and msg.topic or nil
		local payload = payload_of(msg)
		if payload ~= nil then
			if topic_has_prefix(topic, { 'state', 'update', 'summary' }) then
				summary = copy_value(payload)
			elseif is_update_job_topic(topic) then
				local job = copy_value(payload)
				jobs[#jobs + 1] = job
				if not is_terminal_job_state(job.state) then
					if active_job == nil or newest_job_first(job, active_job) then active_job = job end
				end
			elseif is_update_timeline_topic(topic) then
				timelines[topic_at(topic, 4)] = copy_value(payload)
			elseif is_fabric_transfer_topic(topic) then
				local transfer = augment_transfer(payload)
				transfers[#transfers + 1] = transfer
				if transfer_is_active(transfer) then
					if active_transfer == nil or newest_transfer_first(transfer, active_transfer) then active_transfer = transfer end
				end
			end
		end
	end

	table.sort(jobs, newest_job_first)
	table.sort(transfers, newest_transfer_first)

	local transfers_by_job = {}
	for _, transfer in ipairs(transfers) do
		local job_id = transfer_job_id(transfer)
		if type(job_id) == 'string' and job_id ~= '' and transfers_by_job[job_id] == nil then
			transfers_by_job[job_id] = transfer
		end
	end

	for _, job in ipairs(jobs) do
		if type(job) == 'table' then
			job.timeline = timelines[job.job_id]
			job.transfer_status = transfers_by_job[job.job_id]
		end
	end

	if active_job ~= nil and type(active_job) == 'table' then
		active_job.timeline = timelines[active_job.job_id]
		active_job.transfer_status = transfers_by_job[active_job.job_id]
	end

	return {
		version = snapshot and snapshot.version or 0,
		update = summary,
		active_job = active_job,
		active_transfer = active_transfer,
		jobs = jobs,
		transfers = transfers,
	}
end

function M.summary(snapshot, sessions_count, extra)
	local items = snapshot and snapshot.items or {}
	local services = 0
	for _, msg in pairs(items) do
		if topic_has_prefix(msg.topic, { 'svc' }) then services = services + 1 end
	end
	local out = {
		version = snapshot and snapshot.version or 0,
		services = services,
		sessions = sessions_count or 0,
		closed = snapshot and snapshot.closed or false,
		reason = snapshot and snapshot.reason or nil,
	}
	for k, v in pairs(extra or {}) do out[k] = v end
	return out
end

return M
