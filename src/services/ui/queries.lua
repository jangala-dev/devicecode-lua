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
