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

local function item_for(snapshot, topic)
	local key = topics.topic_key(topic)
	local item = snapshot and snapshot.items and snapshot.items[key]
	return item and copy_value(item) or nil
end

local function payload_for(snapshot, topic)
	local item = item_for(snapshot, topic)
	return item and item.payload or nil
end

local function status_from_component_payload(payload)
	if type(payload) ~= 'table' then return nil end
	local snap = type(payload.snapshot) == 'table' and payload.snapshot or payload
	local out = copy_value(snap)
	local established = snap.established == true
	out.established = established
	if out.ready == nil then out.ready = established end
	if out.state == nil then
		if out.ready == true then
			out.state = 'ready'
		else
			out.state = snap.phase or payload.state or 'starting'
		end
	end
	if out.reason == nil then out.reason = snap.why or snap.reason end
	if out.err == nil then out.err = snap.err or snap.last_err end
	return out
end

local function component_view(payload)
	if type(payload) ~= 'table' then return nil end
	local out = copy_value(payload)
	out.status = status_from_component_payload(payload) or out.status
	return out
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
	return item_for(snapshot, topic)
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
		link = payload_for(snapshot, { 'state', 'fabric', 'link', link_id }),
	}
	local components = { 'reader', 'session', 'writer', 'rpc_bridge', 'transfer_manager' }
	for _, component in ipairs(components) do
		local payload = payload_for(snapshot, { 'state', 'fabric', 'link', link_id, 'component', component })
		if payload ~= nil then out[component] = component_view(payload) end
	end
	out.bridge = out.rpc_bridge
	out.transfer = out.transfer_manager
	if out.link == nil and out.session == nil and out.bridge == nil and out.transfer == nil then
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

function M.summary_from_counts(stats, sessions_count, extra)
	stats = stats or {}
	local out = {
		version = stats.version or 0,
		services = stats.services or 0,
		sessions = sessions_count or 0,
		closed = stats.closed or false,
		reason = stats.reason,
	}
	for k, v in pairs(extra or {}) do out[k] = v end
	return out
end

function M.summary(snapshot, sessions_count, extra)
	local items = snapshot and snapshot.items or {}
	local services = 0
	for _, msg in pairs(items) do
		if topic_has_prefix(msg.topic, { 'svc' }) then services = services + 1 end
	end
	return M.summary_from_counts({
		version = snapshot and snapshot.version or 0,
		services = services,
		closed = snapshot and snapshot.closed or false,
		reason = snapshot and snapshot.reason or nil,
	}, sessions_count, extra)
end

return M
