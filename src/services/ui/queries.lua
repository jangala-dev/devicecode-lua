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

local function payload_at(snapshot, topic)
	local item = M.topic(snapshot, topic)
	return item and item.payload or nil
end

local function component_view(payload)
	if type(payload) ~= 'table' then return nil end
	local status = copy_value(payload.snapshot or payload.status or payload)
	if payload.component == 'session' and type(status) == 'table' then
		if status.ready == nil then status.ready = status.established == true end
		if status.state == nil then
			if status.ready then
				status.state = 'ready'
			else
				status.state = status.phase
			end
		end
	end
	return {
		link_id = payload.link_id,
		link_generation = payload.link_generation,
		component = payload.component,
		state = payload.state,
		status = status,
	}
end

function M.fabric_link_status(snapshot, link_id)
	local root = { 'state', 'fabric', 'link', link_id }
	local function component(name)
		return component_view(payload_at(snapshot, {
			'state', 'fabric', 'link', link_id, 'component', name,
		}))
	end

	return {
		version = snapshot and snapshot.version or 0,
		link = component_view(payload_at(snapshot, root)),
		session = component('session'),
		bridge = component('rpc_bridge') or component('bridge'),
		transfer = component('transfer'),
		transfer_manager = component('transfer_manager') or component('transfer'),
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
