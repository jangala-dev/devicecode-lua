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

local function payload_for(snapshot, topic)
	local key = topics.topic_key(topic)
	local item = snapshot and snapshot.items and snapshot.items[key]
	return item and copy_value(item.payload) or nil
end

local function component_status(payload)
	if type(payload) ~= 'table' then return nil end
	local snap = type(payload.snapshot) == 'table' and payload.snapshot or payload.status
	if type(snap) ~= 'table' then return nil end
	local status = copy_value(snap)
	if status.ready == nil and status.established ~= nil then
		status.ready = status.established == true
	end
	if status.state == nil then
		if status.ready == true then
			status.state = 'ready'
		else
			status.state = status.phase
		end
	end
	status.reason = status.reason or status.why
	status.err = status.err or status.last_err
	return {
		link_id = payload.link_id,
		status = status,
	}
end

local function public_job(job)
	if type(job) ~= 'table' then return nil end
	local out = copy_value(job)
	out.lifecycle = out.lifecycle or {
		state = job.state,
		stage = job.stage or job.phase,
		next_step = job.next_step,
		error = job.error,
	}
	out.result = out.result or job.stage_result or job.commit_result
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

function M.fabric_link_status(snapshot, link_id)
	link_id = tostring(link_id or '')
	if link_id == '' then return nil end
	local out = {
		version = snapshot and snapshot.version or 0,
		link_id = link_id,
	}
	out.session = component_status(payload_for(snapshot, { 'state', 'fabric', 'link', link_id, 'component', 'session' }))
	out.transfer_manager = component_status(payload_for(snapshot, { 'state', 'fabric', 'link', link_id, 'component', 'transfer_manager' }))
	out.transfer = out.transfer_manager
	if out.session == nil and out.transfer == nil then
		return nil
	end
	return out
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

function M.update_job_status(snapshot, job_id)
	job_id = tostring(job_id or '')
	if job_id == '' then return nil end
	local payload = payload_for(snapshot, { 'state', 'workflow', 'update-job', job_id })
	local job = public_job(payload)
	if job == nil then return nil end
	return { ok = true, job = job }
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
